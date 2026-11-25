package io.livekit.reactnative.webrtc;

import android.annotation.SuppressLint;
import android.content.Context;
import android.graphics.Color;
import android.graphics.Point;
import android.util.Log;
import android.view.View;
import android.view.ViewGroup;

import androidx.core.view.ViewCompat;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Callback;
import com.facebook.react.bridge.ReactContext;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.uimanager.events.RCTEventEmitter;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.List;
import java.util.Objects;

import livekit.org.webrtc.EglBase;
import livekit.org.webrtc.Logging;
import livekit.org.webrtc.MediaStream;
import livekit.org.webrtc.RendererCommon;
import livekit.org.webrtc.RendererCommon.RendererEvents;
import livekit.org.webrtc.RendererCommon.ScalingType;
import livekit.org.webrtc.SurfaceViewRenderer;
import livekit.org.webrtc.VideoFrame;
import livekit.org.webrtc.VideoSink;
import livekit.org.webrtc.VideoTrack;

public class WebRTCView extends ViewGroup {
    /**
     * The scaling type to be utilized by default.
     *
     * The default value is in accord with
     * https://www.w3.org/TR/html5/embedded-content-0.html#the-video-element:
     *
     * In the absence of style rules to the contrary, video content should be
     * rendered inside the element's playback area such that the video content
     * is shown centered in the playback area at the largest possible size that
     * fits completely within it, with the video content's aspect ratio being
     * preserved. Thus, if the aspect ratio of the playback area does not match
     * the aspect ratio of the video, the video will be shown letterboxed or
     * pillarboxed. Areas of the element's playback area that do not contain the
     * video represent nothing.
     */
    private static final ScalingType DEFAULT_SCALING_TYPE = ScalingType.SCALE_ASPECT_FIT;

    private static final String TAG = WebRTCModule.TAG;

    /**
     * The number of initialized video renderers, used for logging.
     * When the renderer is initialized, it creates a new {@link javax.microedition.khronos.egl.EGLContext}
     * which can throw an exception, probably due to memory limitations. We log the number of instances that can
     * be created before the exception is thrown.
     */
    private static int rendererInstances;

    /**
     * The height of the last video frame rendered by
     * {@link #renderer}.
     */
    private int frameHeight;

    /**
     * The rotation (degree) of the last video frame rendered by
     * {@link #renderer}.
     */
    private int frameRotation;

    /**
     * The width of the last video frame rendered by
     * {@link #renderer}.
     */
    private int frameWidth;

    /**
     * The {@code Object} which synchronizes the access to the layout-related
     * state of this instance such as {@link #frameHeight},
     * {@link #frameRotation}, {@link #frameWidth}, and {@link #scalingType}.
     */
    private final Object layoutSyncRoot = new Object();

    /**
     * The indicator which determines whether this {@code WebRTCView} is to
     * mirror the video represented by {@link #videoTrack} during its rendering.
     */
    private boolean mirror;

    /**
     * Indicates if the renderer is attached to the video
     * track.
     */
    private boolean rendererAttached;

    /**
     * The {@code RendererEvents} which listens to rendering events reported by
     * {@link #renderer}.
     */
    private final RendererEvents rendererEvents = new RendererEvents() {
        @Override
        public void onFirstFrameRendered() {
            WebRTCView.this.onFirstFrameRendered();
        }

        @Override
        public void onFrameResolutionChanged(int videoWidth, int videoHeight, int rotation) {
            WebRTCView.this.onFrameResolutionChanged(videoWidth, videoHeight, rotation);
        }
    };

    /**
     * The {@code Runnable} representation of
     * {@link #requestRendererLayout()}. Explicitly defined in order
     * to allow the use of the latter with {@link #post(Runnable)} without
     * initializing new instances on every (method) call.
     */
    private final Runnable requestRendererLayoutRunnable = new Runnable() {
        @Override
        public void run() {
            requestRendererLayout();
        }
    };

    /**
     * The scaling type this {@code WebRTCView} is to apply to the video
     * represented by {@link #videoTrack} during its rendering. An expression of
     * the CSS property {@code object-fit} in the terms of WebRTC.
     */
    private ScalingType scalingType;

    /**
     * The URL, if any, of the {@link MediaStream} (to be) rendered by this
     * {@code WebRTCView}. The value of {@link #videoTrack} is derived from it.
     */
    private String streamURL;

    /**
     * The URL most recently passed to {@link #setStreamURL(String)}. The track
     * lookup is asynchronous, so a callback for an older URL must be ignored.
     */
    private String requestedStreamURL;

    /**
     * The sink currently added to {@link #videoTrack}. It forwards frames to
     * {@link #renderer} only while it is open, and it is closed on
     * the UI thread as soon as the track is let go, so frames of a previous
     * track are never drawn even if the asynchronous removeSink runs late.
     */
    private TrackSink trackSink;

    private static final class TrackSink implements VideoSink {
        final VideoTrack track;
        final VideoSink renderer;
        private boolean open = true;

        TrackSink(VideoTrack track, VideoSink renderer) {
            this.track = track;
            this.renderer = renderer;
        }

        @Override
        public synchronized void onFrame(VideoFrame frame) {
            if (open) {
                renderer.onFrame(frame);
            }
        }

        synchronized void close() {
            open = false;
        }
    }

    /**
     * The {@link View} which actually renders {@link #videoTrack} on behalf of
     * this instance. It is not added to the track directly: frames reach it
     * through the {@link TrackSink} in {@link #trackSink}.
     */
    private Renderer renderer;
    private int zOrder;

    interface Renderer extends VideoSink {
        void init(EglBase.Context context, RendererEvents events);
        void setMirror(boolean mirror);
        void release();
        void clearImage();
    }

    private static final class SurfaceRenderer extends SurfaceViewRenderer implements Renderer {
        SurfaceRenderer(Context context) {
            super(context);
        }
    }

    /**
     * The {@code VideoTrack}, if any, rendered by this {@code WebRTCView}.
     */
    private VideoTrack videoTrack;

    /**
     * The callback to be called when video dimensions change.
     */
    private boolean onDimensionsChangeEnabled = false;

    public WebRTCView(Context context) {
        super(context);

        scalingType = DEFAULT_SCALING_TYPE;
        installRenderer(new SurfaceRenderer(context));
    }

    private <T extends View & Renderer> void installRenderer(T view) {
        renderer = view;
        renderer.setMirror(mirror);
        if (view instanceof SurfaceViewRenderer) {
            ((SurfaceViewRenderer) view).setScalingType(scalingType);
            setZOrder(zOrder);
        }
        addView(view);
    }

    public void setUseTextureView(boolean useTextureView) {
        if (useTextureView == (renderer instanceof TextureViewRenderer)) {
            return;
        }
        removeRendererFromVideoTrack();
        removeViewAt(0);
        if (useTextureView) {
            installRenderer(new TextureViewRenderer(getContext()));
        } else {
            installRenderer(new SurfaceRenderer(getContext()));
        }
        requestRendererLayout();
        tryAddRendererToVideoTrack();
    }

    private void clearRenderer() {
        if (renderer instanceof SurfaceViewRenderer) {
            ((SurfaceViewRenderer) renderer).setBackgroundColor(Color.BLACK);
        } else {
            // EGL clears asynchronously. Hide any buffered texture frame immediately.
            ((TextureViewRenderer) renderer).setAlpha(0f);
        }
        renderer.clearImage();
    }

    /**
     * Asynchronously retrieves the VideoTrack for the given streamURL.
     * This method avoids blocking the UI thread by performing the lookup
     * on the WebRTC executor thread and posting the result back to the UI thread.
     *
     * @param streamURL The stream URL to lookup
     * @param callback Callback invoked on UI thread with the VideoTrack (or null if not found)
     */
    private void getVideoTrackForStreamURL(String streamURL, java.util.function.Consumer<VideoTrack> callback) {
        if (streamURL == null) {
            callback.accept(null);
            return;
        }

        ReactContext reactContext = (ReactContext) getContext();
        WebRTCModule module = reactContext.getNativeModule(WebRTCModule.class);

        // Submit lookup to executor thread to avoid blocking UI thread
        ThreadUtils.runOnExecutor(() -> {
            try {
                MediaStream stream = module.getStreamForReactTag(streamURL);
                if (stream == null) {
                    Log.w(TAG, "Stream not found for URL: " + streamURL);
                    post(() -> callback.accept(null));
                    return;
                }

                VideoTrack videoTrack = null;
                List<VideoTrack> videoTracks = stream.videoTracks;
                if (!videoTracks.isEmpty()) {
                    videoTrack = videoTracks.get(0);
                }

                if (videoTrack == null) {
                    Log.w(TAG, "No video stream for react tag: " + streamURL);
                    post(() -> callback.accept(null));
                    return;
                }

                // Post result back to UI thread
                final VideoTrack result = videoTrack;
                post(() -> callback.accept(result));
            } catch (Throwable tr) {
                Log.e(TAG, "Error getting video track for stream URL: " + streamURL, tr);
                post(() -> callback.accept(null));
            }
        });
    }

    @Override
    protected void onAttachedToWindow() {
        try {
            // Generally, OpenGL is only necessary while this View is attached
            // to a window so there is no point in having the whole rendering
            // infrastructure hooked up while this View is not attached to a
            // window. Additionally, a memory leak was solved in a similar way
            // on iOS.
            tryAddRendererToVideoTrack();
        } finally {
            super.onAttachedToWindow();
        }
    }

    @Override
    protected void onDetachedFromWindow() {
        try {
            // Generally, OpenGL is only necessary while this View is attached
            // to a window so there is no point in having the whole rendering
            // infrastructure hooked up while this View is not attached to a
            // window. Additionally, a memory leak was solved in a similar way
            // on iOS.
            removeRendererFromVideoTrack();
        } finally {
            super.onDetachedFromWindow();
        }
    }

    /**
     * Callback fired by {@link #renderer} when the first frame is
     * rendered. Here we will set the background of the view part of the
     * SurfaceView to transparent, so the surface (where video is actually
     * rendered) shines through.
     */
    private void onFirstFrameRendered() {
        TrackSink sink = trackSink;
        post(() -> {
            if (sink != trackSink) {
                return;
            }
            if (renderer instanceof SurfaceViewRenderer) {
                ((SurfaceViewRenderer) renderer).setBackgroundColor(Color.TRANSPARENT);
            } else {
                ((TextureViewRenderer) renderer).setAlpha(1f);
            }
        });
    }

    /**
     * Callback fired by {@link #renderer} when the resolution or
     * rotation of the frame it renders has changed.
     *
     * @param videoWidth The new width of the rendered video frame.
     * @param videoHeight The new height of the rendered video frame.
     * @param rotation The new rotation of the rendered video frame.
     */
    private void onFrameResolutionChanged(int videoWidth, int videoHeight, int rotation) {
        boolean changed = false;

        synchronized (layoutSyncRoot) {
            if (this.frameHeight != videoHeight) {
                this.frameHeight = videoHeight;
                changed = true;
            }
            if (this.frameRotation != rotation) {
                this.frameRotation = rotation;
                changed = true;
            }
            if (this.frameWidth != videoWidth) {
                this.frameWidth = videoWidth;
                changed = true;
            }
        }
        if (changed) {
            // The onFrameResolutionChanged method call executes on the
            // video sink's thread.
            post(requestRendererLayoutRunnable);

            // Call the onDimensionsChange callback if it's enabled
            if (onDimensionsChangeEnabled) {
                TrackSink sink = trackSink;
                post(() -> {
                    if (sink != trackSink) {
                        return;
                    }
                    try {
                        ReactContext reactContext = (ReactContext) getContext();
                        WritableMap params = Arguments.createMap();
                        params.putInt("width", videoWidth);
                        params.putInt("height", videoHeight);

                        // Send the event through React Native's event system
                        reactContext.getJSModule(RCTEventEmitter.class)
                                .receiveEvent(getId(), "onDimensionsChange", params);
                    } catch (Exception e) {
                        Log.e(TAG, "Error calling onDimensionsChange callback", e);
                    }
                });
            }
        }
    }

    @Override
    protected void onLayout(boolean changed, int l, int t, int r, int b) {
        int height = b - t;
        int width = r - l;

        if (height == 0 || width == 0) {
            l = t = r = b = 0;
        } else {
            int frameHeight;
            int frameRotation;
            int frameWidth;
            ScalingType scalingType;

            synchronized (layoutSyncRoot) {
                frameHeight = this.frameHeight;
                frameRotation = this.frameRotation;
                frameWidth = this.frameWidth;
                scalingType = this.scalingType;
            }

            switch (scalingType) {
                case SCALE_ASPECT_FILL:
                    // Fill this ViewGroup with the renderer and the latter
                    // will take care of filling itself with the video similarly to
                    // the cover value the CSS property object-fit.
                    r = width;
                    l = 0;
                    b = height;
                    t = 0;
                    break;
                case SCALE_ASPECT_FIT:
                default:
                    // Lay the renderer out inside this ViewGroup in accord
                    // with the contain value of the CSS property object-fit.
                    // SurfaceViewRenderer will fill itself with the video similarly
                    // to the cover or contain value of the CSS property object-fit
                    // (which will not matter, eventually).
                    if (frameHeight == 0 || frameWidth == 0) {
                        l = t = r = b = 0;
                    } else {
                        float frameAspectRatio = (frameRotation % 180 == 0) ? frameWidth / (float) frameHeight
                                                                            : frameHeight / (float) frameWidth;
                        Point frameDisplaySize =
                                RendererCommon.getDisplaySize(scalingType, frameAspectRatio, width, height);

                        l = (width - frameDisplaySize.x) / 2;
                        t = (height - frameDisplaySize.y) / 2;
                        r = l + frameDisplaySize.x;
                        b = t + frameDisplaySize.y;
                    }
                    break;
            }
        }
        getChildAt(0).layout(l, t, r, b);
    }

    /**
     * Stops rendering {@link #videoTrack} and releases the associated acquired
     * resources (if rendering is in progress).
     */
    private void removeRendererFromVideoTrack() {
        if (rendererAttached) {
            // Capture the sink now: by the time the executor runs, the
            // videoTrack field may already be null or the next track.
            final TrackSink sink = trackSink;
            if (sink != null) {
                sink.close();
                trackSink = null;
                ThreadUtils.runOnExecutor(() -> {
                    try {
                        sink.track.removeSink(sink);
                    } catch (IllegalStateException e) {
                        // XXX If WebRTCModule#mediaStreamTrackRelease has already been
                        // invoked on the track this sink was added to, then the track is
                        // disposed and removeSink throws IllegalStateException. That is
                        // expected and there is nothing left to remove.
                    } catch (Throwable tr) {
                        Log.w(TAG, "Failed to remove renderer", tr);
                    }
                });
            }

            renderer.release();
            rendererInstances--;
            rendererAttached = false;

            // Since this WebRTCView is no longer rendering anything, make sure
            // the renderer displays nothing as well.
            synchronized (layoutSyncRoot) {
                frameHeight = 0;
                frameRotation = 0;
                frameWidth = 0;
            }
            requestRendererLayout();
        }
    }

    /**
     * Request that {@link #renderer} be laid out (as soon as
     * possible) because layout-related state either of this instance or of
     * its child renderer has changed.
     */
    @SuppressLint("WrongCall")
    private void requestRendererLayout() {
        // Google/WebRTC just call requestLayout() on surfaceViewRenderer when
        // they change the value of its mirror or surfaceType property.
        getChildAt(0).requestLayout();
        // The above is not enough though when the video frame's dimensions or
        // rotation change. The following will suffice.
        if (!ViewCompat.isInLayout(this)) {
            onLayout(
                    /* changed */ false, getLeft(), getTop(), getRight(), getBottom());
        }
    }

    /**
     * Sets the indicator which determines whether this {@code WebRTCView} is to
     * mirror the video represented by {@link #videoTrack} during its rendering.
     *
     * @param mirror If this {@code WebRTCView} is to mirror the video
     * represented by {@code videoTrack} during its rendering, {@code true};
     * otherwise, {@code false}.
     */
    public void setMirror(boolean mirror) {
        if (this.mirror != mirror) {
            this.mirror = mirror;
            renderer.setMirror(mirror);
            // SurfaceViewRenderer takes the value of its mirror property into
            // account upon its layout.
            requestRendererLayout();
        }
    }

    /**
     * In the fashion of
     * https://www.w3.org/TR/html5/embedded-content-0.html#dom-video-videowidth
     * and https://www.w3.org/TR/html5/rendering.html#video-object-fit,
     * resembles the CSS style {@code object-fit}.
     *
     * @param objectFit For details, refer to the documentation of the
     * {@code objectFit} property of the JavaScript counterpart of
     * {@code WebRTCView} i.e. {@code RTCView}.
     */
    public void setObjectFit(String objectFit) {
        ScalingType scalingType =
                "cover".equals(objectFit) ? ScalingType.SCALE_ASPECT_FILL : ScalingType.SCALE_ASPECT_FIT;

        setScalingType(scalingType);
    }

    private void setScalingType(ScalingType scalingType) {
        synchronized (layoutSyncRoot) {
            if (this.scalingType == scalingType) {
                return;
            }
            this.scalingType = scalingType;
            if (renderer instanceof SurfaceViewRenderer) {
                ((SurfaceViewRenderer) renderer).setScalingType(scalingType);
            }
        }
        // Both this instance ant its SurfaceViewRenderer take the value of
        // their scalingType properties into account upon their layouts.
        requestRendererLayout();
    }

    /**
     * Sets the {@code MediaStream} to be rendered by this {@code WebRTCView}.
     * The implementation renders the first {@link VideoTrack}, if any, of the
     * specified {@code mediaStream}.
     *
     * @param streamURL The URL of the {@code MediaStream} to be rendered by
     * this {@code WebRTCView} or {@code null}.
     */
    void setStreamURL(String streamURL) {
        Log.d(TAG,
                "Set stream URL " + streamURL + " requested: " + this.requestedStreamURL
                        + " applied: " + this.streamURL);
        // Compare with the last requested URL, not the applied one, which is
        // only updated once the asynchronous lookup below completes.
        if (Objects.equals(streamURL, this.requestedStreamURL)) {
            return;
        }
        this.requestedStreamURL = streamURL;

        // The value of this.streamURL is really changing. Look up the new
        // videoTrack asynchronously and, once the lookup completes, let go of
        // the old videoTrack (only if the track really changes) and render
        // the new one. removeRendererFromVideoTrack removes exactly the
        // TrackSink that was added to the old videoTrack and closes it right
        // away, so the old track's frames are not drawn after the switch even
        // if the asynchronous removeSink runs late.
        getVideoTrackForStreamURL(streamURL, videoTrack -> {
            Log.d(TAG, "Got video track for stream URL " + streamURL + " -> " + videoTrack);
            if (!Objects.equals(streamURL, this.requestedStreamURL)) {
                // A newer setStreamURL call superseded this one.
                Log.d(TAG, "Ignoring stale track lookup for " + streamURL + ", requested: " + requestedStreamURL);
                return;
            }
            if (this.videoTrack != videoTrack) {
                setVideoTrack(null);
            }

            this.streamURL = streamURL;

            // After realizing/applying the change in the value of
            // this.streamURL, reflect it on the value of videoTrack.
            setVideoTrack(videoTrack);
        });
    }

    /**
     * Sets the {@code VideoTrack} to be rendered by this {@code WebRTCView}.
     *
     * @param videoTrack The {@code VideoTrack} to be rendered by this
     * {@code WebRTCView} or {@code null}.
     */
    private void setVideoTrack(VideoTrack videoTrack) {
        VideoTrack oldVideoTrack = this.videoTrack;

        if (oldVideoTrack != videoTrack) {
            if (oldVideoTrack != null) {
                if (videoTrack == null) {
                    // If we are not going to render any stream, clean the
                    // surface.
                    clearRenderer();
                }
                removeRendererFromVideoTrack();
            }

            this.videoTrack = videoTrack;

            if (videoTrack != null) {
                tryAddRendererToVideoTrack();
                if (oldVideoTrack == null) {
                    // If there was no old track, clean the surface so we start
                    // with black.
                    clearRenderer();
                }
            }
        }
    }

    /**
     * Sets the z-order of this {@link WebRTCView} in the stacking space of all
     * {@code WebRTCView}s. For more details, refer to the documentation of the
     * {@code zOrder} property of the JavaScript counterpart of
     * {@code WebRTCView} i.e. {@code RTCView}.
     *
     * @param zOrder The z-order to set on this {@code WebRTCView}.
     */
    public void setZOrder(int zOrder) {
        this.zOrder = zOrder;
        if (!(renderer instanceof SurfaceViewRenderer)) {
            // TextureView uses the normal Android view stacking order.
            return;
        }
        SurfaceViewRenderer surfaceViewRenderer = (SurfaceViewRenderer) renderer;
        switch (zOrder) {
            case 0:
                surfaceViewRenderer.setZOrderMediaOverlay(false);
                break;
            case 1:
                surfaceViewRenderer.setZOrderMediaOverlay(true);
                break;
            case 2:
                surfaceViewRenderer.setZOrderOnTop(true);
                break;
        }
    }

    /**
     * Starts rendering {@link #videoTrack} if rendering is not in progress and
     * all preconditions for the start of rendering are met.
     */
    private void tryAddRendererToVideoTrack() {
        if (!rendererAttached && videoTrack != null && ViewCompat.isAttachedToWindow(this)) {
            EglBase.Context sharedContext = EglUtils.getRootEglBaseContext();

            if (sharedContext == null) {
                // If SurfaceViewRenderer#init() is invoked, it will throw a
                // RuntimeException which will very likely kill the application.
                Log.e(TAG, "Failed to render a VideoTrack!");
                return;
            }

            try {
                renderer.init(sharedContext, rendererEvents);
                rendererInstances++;
            } catch (Exception e) {
                Logging.e(
                        TAG, "Failed to initialize video renderer on instance " + rendererInstances, e);
                return;
            }

            // Add a sink for exactly this track; the videoTrack field may
            // already hold another track when the executor runs.
            final TrackSink sink = new TrackSink(videoTrack, renderer);
            trackSink = sink;
            ThreadUtils.runOnExecutor(() -> {
                try {
                    sink.track.addSink(sink);
                } catch (IllegalStateException e) {
                    // XXX If WebRTCModule#mediaStreamTrackRelease has already been
                    // invoked on the track this sink is for, then the track is
                    // disposed and addSink throws IllegalStateException. That is
                    // expected: the track is gone, so there is nothing to render.
                } catch (Throwable tr) {
                    Log.w(TAG, "Failed to add renderer", tr);
                }
            });

            rendererAttached = true;
        }
    }

    /**
     * Sets whether the onDimensionsChange callback should be called.
     *
     * @param enabled Whether the callback should be enabled.
     */
    public void setOnDimensionsChange(boolean enabled) {
        this.onDimensionsChangeEnabled = enabled;
    }
}
