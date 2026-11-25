package io.livekit.reactnative.webrtc;

import android.content.Context;
import android.graphics.SurfaceTexture;
import android.view.TextureView;

import java.util.concurrent.CountDownLatch;

import livekit.org.webrtc.EglBase;
import livekit.org.webrtc.GlRectDrawer;
import livekit.org.webrtc.RendererCommon.RendererEvents;
import livekit.org.webrtc.SurfaceEglRenderer;
import livekit.org.webrtc.VideoFrame;

/** Renders video within Android's normal view hierarchy for clipping and overlays. */
final class TextureViewRenderer extends TextureView implements WebRTCView.Renderer, TextureView.SurfaceTextureListener {
    private final SurfaceEglRenderer eglRenderer = new SurfaceEglRenderer("WebRTCTextureView");

    TextureViewRenderer(Context context) {
        super(context);
        setOpaque(false);
        setSurfaceTextureListener(this);
    }

    @Override
    public void init(EglBase.Context context, RendererEvents events) {
        eglRenderer.init(context, events, EglBase.CONFIG_PLAIN, new GlRectDrawer());
    }

    @Override
    public void onFrame(VideoFrame frame) {
        eglRenderer.onFrame(frame);
    }

    @Override
    public void setMirror(boolean mirror) {
        eglRenderer.setMirror(mirror);
    }

    @Override
    public void clearImage() {
        eglRenderer.clearImage();
    }

    @Override
    public void release() {
        eglRenderer.release();
    }

    @Override
    protected void onLayout(boolean changed, int left, int top, int right, int bottom) {
        super.onLayout(changed, left, top, right, bottom);
        // The parent sizes the child for contain. EGL center-crops to the child
        // aspect ratio for cover, accounting for the frame's rotation.
        int height = bottom - top;
        eglRenderer.setLayoutAspectRatio(height == 0 ? 0f : (float) (right - left) / height);
    }

    @Override
    public void onSurfaceTextureAvailable(SurfaceTexture surface, int width, int height) {
        eglRenderer.createEglSurface(surface);
    }

    @Override
    public boolean onSurfaceTextureDestroyed(SurfaceTexture surface) {
        // Android releases the texture when this returns true. Wait until the
        // rendering thread has relinquished the EGL surface before returning.
        CountDownLatch released = new CountDownLatch(1);
        eglRenderer.releaseEglSurface(released::countDown);
        livekit.org.webrtc.ThreadUtils.awaitUninterruptibly(released);
        return true;
    }

    @Override
    public void onSurfaceTextureSizeChanged(SurfaceTexture surface, int width, int height) {}

    @Override
    public void onSurfaceTextureUpdated(SurfaceTexture surface) {}
}
