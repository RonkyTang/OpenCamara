package com.ronky.opencamara.tv;

import android.Manifest;
import android.app.Activity;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Matrix;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.HandlerThread;
import android.provider.MediaStore;
import android.util.Log;
import android.util.Size;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Date;
import java.util.List;
import java.util.Locale;

public final class MainActivity extends Activity {
    private static final String TAG = "OpenCamaraTV";
    private static final String ACTION_USB_PERMISSION =
            "com.ronky.opencamara.tv.USB_PERMISSION";
    private static final int CAMERA_PERMISSION_REQUEST = 1001;
    private static final int STORAGE_PERMISSION_REQUEST = 1002;
    private static final long MAX_PREVIEW_PIXELS = 1920L * 1080L;
    private static final String PREFERENCES_NAME = "viewer_preferences";
    private static final String PREFERENCE_MIRRORED = "mirrored";

    private AutoFitTextureView previewView;
    private View statusPanel;
    private TextView statusTitle;
    private TextView statusDetail;
    private TextView usbBadge;
    private TextView bottomHint;
    private ProgressBar progressBar;
    private Button retryButton;
    private Button mirrorButton;
    private Button photoButton;
    private boolean mirrored;

    private UsbManager usbManager;
    private CameraManager cameraManager;
    private UsbDevice activeUsbDevice;
    private CameraDevice cameraDevice;
    private CameraCaptureSession captureSession;
    private Surface previewSurface;
    private Size previewSize;
    private String pendingCameraId;
    private volatile boolean openingCamera;
    private volatile boolean discoveringCamera;
    private boolean receiverRegistered;

    private HandlerThread cameraThread;
    private Handler cameraHandler;

    private final BroadcastReceiver usbReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            String action = intent.getAction();
            UsbDevice device = usbDeviceExtra(intent);
            if (ACTION_USB_PERMISSION.equals(action)) {
                if (device != null && intent.getBooleanExtra(
                        UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                    activeUsbDevice = device;
                    updateUsbBadge(device);
                    showLoading(R.string.status_connecting, R.string.detail_opening_camera);
                    discoverAndOpenCamera();
                } else {
                    showError(R.string.status_permission_denied,
                            R.string.detail_usb_permission_denied);
                }
            } else if (UsbManager.ACTION_USB_DEVICE_ATTACHED.equals(action)) {
                if (device == null || isVideoDevice(device)) {
                    beginCameraFlow();
                }
            } else if (UsbManager.ACTION_USB_DEVICE_DETACHED.equals(action)) {
                if (device == null || activeUsbDevice == null
                        || device.getDeviceId() == activeUsbDevice.getDeviceId()) {
                    activeUsbDevice = null;
                    closeCamera();
                    showNoCamera();
                }
            }
        }
    };

    private final CameraManager.AvailabilityCallback availabilityCallback =
            new CameraManager.AvailabilityCallback() {
                @Override
                public void onCameraAvailable(String cameraId) {
                    if (activeUsbDevice != null && cameraDevice == null && !openingCamera) {
                        discoverAndOpenCamera();
                    }
                }
            };

    private final TextureView.SurfaceTextureListener surfaceTextureListener =
            new TextureView.SurfaceTextureListener() {
                @Override
                public void onSurfaceTextureAvailable(SurfaceTexture surface, int width, int height) {
                    if (pendingCameraId != null) {
                        openSelectedCamera();
                    } else {
                        beginCameraFlow();
                    }
                }

                @Override
                public void onSurfaceTextureSizeChanged(
                        SurfaceTexture surface, int width, int height) {
                    // The Activity is locked to landscape; AutoFitTextureView handles resizing.
                }

                @Override
                public boolean onSurfaceTextureDestroyed(SurfaceTexture surface) {
                    closeCamera();
                    return true;
                }

                @Override
                public void onSurfaceTextureUpdated(SurfaceTexture surface) {
                }
            };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        previewView = findViewById(R.id.camera_preview);
        statusPanel = findViewById(R.id.status_panel);
        statusTitle = findViewById(R.id.status_title);
        statusDetail = findViewById(R.id.status_detail);
        usbBadge = findViewById(R.id.usb_badge);
        bottomHint = findViewById(R.id.bottom_hint);
        progressBar = findViewById(R.id.progress);
        retryButton = findViewById(R.id.retry_button);
        mirrorButton = findViewById(R.id.mirror_button);
        photoButton = findViewById(R.id.photo_button);

        usbManager = (UsbManager) getSystemService(Context.USB_SERVICE);
        cameraManager = (CameraManager) getSystemService(Context.CAMERA_SERVICE);
        previewView.setSurfaceTextureListener(surfaceTextureListener);
        retryButton.setOnClickListener(view -> beginCameraFlow());
        mirrored = getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
                .getBoolean(PREFERENCE_MIRRORED, false);
        applyMirrorSetting();
        mirrorButton.setOnClickListener(view -> toggleMirror());
        photoButton.setOnClickListener(view -> capturePhoto());
        showLoading(R.string.status_checking, R.string.detail_checking_usb);
        enterImmersiveMode();
    }

    @Override
    protected void onStart() {
        super.onStart();
        registerUsbReceiver();
    }

    @Override
    protected void onResume() {
        super.onResume();
        enterImmersiveMode();
        startCameraThread();
        cameraManager.registerAvailabilityCallback(availabilityCallback, cameraHandler);
        beginCameraFlow();
    }

    @Override
    protected void onPause() {
        cameraManager.unregisterAvailabilityCallback(availabilityCallback);
        closeCamera();
        stopCameraThread();
        super.onPause();
    }

    @Override
    protected void onStop() {
        unregisterUsbReceiver();
        super.onStop();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            enterImmersiveMode();
        }
    }

    private void beginCameraFlow() {
        closeCamera();
        activeUsbDevice = findUsbVideoDevice();
        if (activeUsbDevice == null) {
            showNoCamera();
            return;
        }

        updateUsbBadge(activeUsbDevice);
        if (checkSelfPermission(Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED) {
            showLoading(R.string.status_permission_required,
                    R.string.detail_camera_permission);
            requestPermissions(new String[]{Manifest.permission.CAMERA},
                    CAMERA_PERMISSION_REQUEST);
            return;
        }

        if (!usbManager.hasPermission(activeUsbDevice)) {
            requestUsbPermission(activeUsbDevice);
            return;
        }

        showLoading(R.string.status_connecting, R.string.detail_opening_camera);
        discoverAndOpenCamera();
    }

    @Override
    public void onRequestPermissionsResult(
            int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == STORAGE_PERMISSION_REQUEST) {
            if (grantResults.length > 0
                    && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                capturePhotoNow();
            } else {
                Toast.makeText(this, R.string.storage_permission_denied,
                        Toast.LENGTH_LONG).show();
            }
            return;
        }
        if (requestCode != CAMERA_PERMISSION_REQUEST) {
            return;
        }
        if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            beginCameraFlow();
        } else {
            showError(R.string.status_permission_denied,
                    R.string.detail_camera_permission_denied);
        }
    }

    private void requestUsbPermission(UsbDevice device) {
        showLoading(R.string.status_usb_permission, R.string.detail_usb_permission);
        Intent permissionIntent = new Intent(ACTION_USB_PERMISSION)
                .setPackage(getPackageName());
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            flags |= PendingIntent.FLAG_MUTABLE;
        }
        PendingIntent pendingIntent = PendingIntent.getBroadcast(this, 0,
                permissionIntent, flags);
        usbManager.requestPermission(device, pendingIntent);
    }

    private void discoverAndOpenCamera() {
        if (cameraHandler == null || discoveringCamera || openingCamera || cameraDevice != null) {
            return;
        }
        discoveringCamera = true;
        cameraHandler.post(() -> {
            try {
                String cameraId = selectExternalCamera(cameraManager);
                if (cameraId == null) {
                    discoveringCamera = false;
                    showError(R.string.status_camera_unavailable,
                            R.string.detail_camera2_unavailable);
                    return;
                }
                pendingCameraId = cameraId;
                CameraCharacteristics characteristics =
                        cameraManager.getCameraCharacteristics(cameraId);
                StreamConfigurationMap map = characteristics.get(
                        CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
                if (map == null) {
                    discoveringCamera = false;
                    showError(R.string.status_camera_unavailable,
                            R.string.detail_no_preview_size);
                    return;
                }
                previewSize = choosePreviewSize(
                        map.getOutputSizes(SurfaceTexture.class), screenAspectRatio());
                if (previewSize == null) {
                    discoveringCamera = false;
                    showError(R.string.status_camera_unavailable,
                            R.string.detail_no_preview_size);
                    return;
                }
                discoveringCamera = false;
                runOnUiThread(() -> {
                    previewView.setAspectRatio(previewSize.getWidth(), previewSize.getHeight());
                    if (previewView.isAvailable()) {
                        openSelectedCamera();
                    }
                });
            } catch (CameraAccessException | IllegalArgumentException error) {
                discoveringCamera = false;
                Log.e(TAG, "Unable to inspect external camera", error);
                showError(R.string.status_camera_unavailable,
                        R.string.detail_camera2_error);
            }
        });
    }

    private void openSelectedCamera() {
        if (pendingCameraId == null || previewSize == null || openingCamera
                || cameraDevice != null || cameraHandler == null
                || !previewView.isAvailable()) {
            return;
        }
        if (checkSelfPermission(Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED) {
            return;
        }
        try {
            openingCamera = true;
            cameraManager.openCamera(pendingCameraId, cameraStateCallback, cameraHandler);
        } catch (CameraAccessException | SecurityException error) {
            openingCamera = false;
            Log.e(TAG, "Unable to open external camera", error);
            showError(R.string.status_camera_unavailable, R.string.detail_camera2_error);
        }
    }

    private final CameraDevice.StateCallback cameraStateCallback =
            new CameraDevice.StateCallback() {
                @Override
                public void onOpened(CameraDevice camera) {
                    openingCamera = false;
                    cameraDevice = camera;
                    createPreviewSession();
                }

                @Override
                public void onDisconnected(CameraDevice camera) {
                    openingCamera = false;
                    camera.close();
                    if (cameraDevice == camera) {
                        cameraDevice = null;
                    }
                    showError(R.string.status_disconnected, R.string.detail_reconnect_camera);
                }

                @Override
                public void onError(CameraDevice camera, int error) {
                    openingCamera = false;
                    camera.close();
                    if (cameraDevice == camera) {
                        cameraDevice = null;
                    }
                    Log.e(TAG, "Camera device error: " + error);
                    showError(R.string.status_camera_unavailable,
                            R.string.detail_camera2_error);
                }
            };

    private void createPreviewSession() {
        SurfaceTexture texture = previewView.getSurfaceTexture();
        if (texture == null || cameraDevice == null || previewSize == null) {
            return;
        }
        texture.setDefaultBufferSize(previewSize.getWidth(), previewSize.getHeight());
        previewSurface = new Surface(texture);
        try {
            CaptureRequest.Builder request = cameraDevice.createCaptureRequest(
                    CameraDevice.TEMPLATE_PREVIEW);
            request.addTarget(previewSurface);
            cameraDevice.createCaptureSession(
                    Collections.singletonList(previewSurface),
                    new CameraCaptureSession.StateCallback() {
                        @Override
                        public void onConfigured(CameraCaptureSession session) {
                            if (cameraDevice == null) {
                                session.close();
                                return;
                            }
                            captureSession = session;
                            try {
                                request.set(CaptureRequest.CONTROL_MODE,
                                        CaptureRequest.CONTROL_MODE_AUTO);
                                session.setRepeatingRequest(request.build(), null, cameraHandler);
                                showPreviewReady();
                            } catch (CameraAccessException error) {
                                Log.e(TAG, "Unable to start preview", error);
                                showError(R.string.status_camera_unavailable,
                                        R.string.detail_preview_failed);
                            }
                        }

                        @Override
                        public void onConfigureFailed(CameraCaptureSession session) {
                            showError(R.string.status_camera_unavailable,
                                    R.string.detail_preview_failed);
                        }
                    },
                    cameraHandler);
        } catch (CameraAccessException error) {
            Log.e(TAG, "Unable to create preview session", error);
            showError(R.string.status_camera_unavailable, R.string.detail_preview_failed);
        }
    }

    private synchronized void closeCamera() {
        discoveringCamera = false;
        openingCamera = false;
        pendingCameraId = null;
        if (captureSession != null) {
            captureSession.close();
            captureSession = null;
        }
        if (cameraDevice != null) {
            cameraDevice.close();
            cameraDevice = null;
        }
        if (previewSurface != null) {
            previewSurface.release();
            previewSurface = null;
        }
    }

    private UsbDevice findUsbVideoDevice() {
        List<UsbDevice> devices = new ArrayList<>(usbManager.getDeviceList().values());
        devices.sort(Comparator.comparingInt(UsbDevice::getDeviceId));
        for (UsbDevice device : devices) {
            if (isVideoDevice(device)) {
                return device;
            }
        }
        return null;
    }

    private static boolean isVideoDevice(UsbDevice device) {
        if (device.getDeviceClass() == UsbConstants.USB_CLASS_VIDEO) {
            return true;
        }
        for (int index = 0; index < device.getInterfaceCount(); index++) {
            UsbInterface usbInterface = device.getInterface(index);
            if (usbInterface.getInterfaceClass() == UsbConstants.USB_CLASS_VIDEO) {
                return true;
            }
        }
        return false;
    }

    private static String selectExternalCamera(CameraManager manager)
            throws CameraAccessException {
        String[] ids = manager.getCameraIdList();
        if (ids.length == 0) {
            return null;
        }

        // Prefer the standards-compliant external-camera marker when the TV firmware provides it.
        for (String id : ids) {
            Integer facing = manager.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.LENS_FACING);
            if (facing != null && facing == CameraCharacteristics.LENS_FACING_EXTERNAL) {
                return id;
            }
        }
        // Most TVs have no built-in camera, so a sole Camera2 device is the USB camera even on
        // vendor firmware that labels it as front/back instead of external.
        if (ids.length == 1) {
            return ids[0];
        }

        String bestId = null;
        int bestScore = Integer.MIN_VALUE;
        for (String id : ids) {
            CameraCharacteristics characteristics = manager.getCameraCharacteristics(id);
            Integer facing = characteristics.get(CameraCharacteristics.LENS_FACING);
            int score = 0;
            boolean plausibleExternal = facing == null;
            if (facing == null) {
                score += 200;
            }
            try {
                int numericId = Integer.parseInt(id);
                if (numericId >= 2) {
                    plausibleExternal = true;
                    score += 100 + numericId;
                }
            } catch (NumberFormatException ignored) {
                plausibleExternal = true;
                score += 150;
            }
            if (plausibleExternal && score > bestScore) {
                bestScore = score;
                bestId = id;
            }
        }
        return bestId;
    }

    static Size choosePreviewSize(Size[] choices, double targetAspect) {
        if (choices == null || choices.length == 0) {
            return null;
        }
        Size best = choices[0];
        double bestScore = previewSizeScore(best, targetAspect);
        for (int index = 1; index < choices.length; index++) {
            double score = previewSizeScore(choices[index], targetAspect);
            if (score < bestScore) {
                best = choices[index];
                bestScore = score;
            }
        }
        return best;
    }

    private static double previewSizeScore(Size size, double targetAspect) {
        long pixels = (long) size.getWidth() * size.getHeight();
        double aspect = (double) size.getWidth() / size.getHeight();
        double aspectPenalty = Math.abs(aspect - targetAspect) * 10_000_000.0;
        if (pixels > MAX_PREVIEW_PIXELS) {
            return aspectPenalty + MAX_PREVIEW_PIXELS + (pixels - MAX_PREVIEW_PIXELS) * 4.0;
        }
        return aspectPenalty + (MAX_PREVIEW_PIXELS - pixels);
    }

    private double screenAspectRatio() {
        int width = getResources().getDisplayMetrics().widthPixels;
        int height = getResources().getDisplayMetrics().heightPixels;
        return height == 0 ? 16.0 / 9.0 : (double) width / height;
    }

    private void showPreviewReady() {
        runOnUiThread(() -> {
            statusPanel.setVisibility(View.GONE);
            retryButton.setVisibility(View.GONE);
            bottomHint.setVisibility(View.GONE);
            photoButton.setEnabled(true);
            photoButton.requestFocus();
            if (previewSize != null) {
                usbBadge.setText(getString(R.string.usb_connected_resolution,
                        previewSize.getWidth(), previewSize.getHeight()));
            }
        });
    }

    private void toggleMirror() {
        mirrored = !mirrored;
        getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
                .edit()
                .putBoolean(PREFERENCE_MIRRORED, mirrored)
                .apply();
        applyMirrorSetting();
    }

    private void applyMirrorSetting() {
        previewView.setScaleX(mirrored ? -1f : 1f);
        mirrorButton.setText(mirrored ? R.string.mirror_on : R.string.mirror_off);
    }

    private void capturePhoto() {
        if (cameraDevice == null || !previewView.isAvailable()) {
            Toast.makeText(this, R.string.photo_unavailable, Toast.LENGTH_SHORT).show();
            return;
        }
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P
                && checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.WRITE_EXTERNAL_STORAGE},
                    STORAGE_PERMISSION_REQUEST);
            return;
        }
        capturePhotoNow();
    }

    private void capturePhotoNow() {
        if (cameraDevice == null || !previewView.isAvailable() || cameraHandler == null) {
            Toast.makeText(this, R.string.photo_unavailable, Toast.LENGTH_SHORT).show();
            return;
        }
        Bitmap source = previewView.getBitmap();
        if (source == null) {
            Toast.makeText(this, R.string.photo_unavailable, Toast.LENGTH_SHORT).show();
            return;
        }

        Bitmap photo = source;
        if (mirrored) {
            Matrix transform = new Matrix();
            transform.setScale(-1f, 1f);
            photo = Bitmap.createBitmap(source, 0, 0,
                    source.getWidth(), source.getHeight(), transform, true);
            if (photo != source) {
                source.recycle();
            }
        }

        photoButton.setEnabled(false);
        Bitmap photoToSave = photo;
        cameraHandler.post(() -> {
            String savedPath = null;
            try {
                savedPath = savePhoto(photoToSave);
            } catch (IOException error) {
                Log.e(TAG, "Unable to save photo", error);
            } finally {
                photoToSave.recycle();
            }
            String finalSavedPath = savedPath;
            runOnUiThread(() -> {
                photoButton.setEnabled(cameraDevice != null);
                photoButton.requestFocus();
                if (finalSavedPath == null) {
                    Toast.makeText(this, R.string.photo_failed, Toast.LENGTH_LONG).show();
                } else {
                    Toast.makeText(this, getString(R.string.photo_saved, finalSavedPath),
                            Toast.LENGTH_LONG).show();
                }
            });
        });
    }

    private String savePhoto(Bitmap photo) throws IOException {
        long capturedAtMillis = System.currentTimeMillis();
        String fileName = "Photo_" + new SimpleDateFormat(
                "yyyyMMdd_HHmmss_SSS", Locale.US).format(new Date(capturedAtMillis)) + ".jpg";
        String relativeFolder = Environment.DIRECTORY_DCIM + "/OpenCamaraTV";

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ContentValues values = new ContentValues();
            values.put(MediaStore.Images.Media.DISPLAY_NAME, fileName);
            values.put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg");
            values.put(MediaStore.Images.Media.RELATIVE_PATH, relativeFolder);
            values.put(MediaStore.Images.Media.DATE_TAKEN, capturedAtMillis);
            values.put(MediaStore.Images.Media.DATE_ADDED, capturedAtMillis / 1000L);
            values.put(MediaStore.Images.Media.DATE_MODIFIED, capturedAtMillis / 1000L);
            values.put(MediaStore.Images.Media.IS_PENDING, 1);
            Uri uri = getContentResolver().insert(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
            if (uri == null) {
                throw new IOException("MediaStore did not create an image entry");
            }
            try {
                try (OutputStream output = getContentResolver().openOutputStream(uri)) {
                    if (output == null || !photo.compress(Bitmap.CompressFormat.JPEG, 95, output)) {
                        throw new IOException("Could not encode JPEG");
                    }
                }
                values.clear();
                values.put(MediaStore.Images.Media.IS_PENDING, 0);
                getContentResolver().update(uri, values, null, null);
            } catch (IOException error) {
                getContentResolver().delete(uri, null, null);
                throw error;
            }
        } else {
            saveLegacyPhoto(photo, fileName, capturedAtMillis);
        }
        return relativeFolder + "/" + fileName;
    }

    @SuppressWarnings("deprecation")
    private void saveLegacyPhoto(Bitmap photo, String fileName, long capturedAtMillis)
            throws IOException {
        File dcim = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM);
        File folder = new File(dcim, "OpenCamaraTV");
        if (!folder.exists() && !folder.mkdirs()) {
            throw new IOException("Could not create photo directory");
        }
        File outputFile = new File(folder, fileName);
        try (OutputStream output = new FileOutputStream(outputFile)) {
            if (!photo.compress(Bitmap.CompressFormat.JPEG, 95, output)) {
                throw new IOException("Could not encode JPEG");
            }
        }
        outputFile.setLastModified(capturedAtMillis);
        MediaScannerConnection.scanFile(this,
                new String[]{outputFile.getAbsolutePath()},
                new String[]{"image/jpeg"}, null);
    }

    private void showNoCamera() {
        runOnUiThread(() -> {
            usbBadge.setText(R.string.usb_not_connected);
            statusPanel.setVisibility(View.VISIBLE);
            statusTitle.setText(R.string.status_no_camera);
            statusDetail.setText(R.string.detail_connect_uvc);
            progressBar.setVisibility(View.GONE);
            retryButton.setVisibility(View.VISIBLE);
            photoButton.setEnabled(false);
            bottomHint.setVisibility(View.VISIBLE);
            retryButton.requestFocus();
        });
    }

    private void showLoading(int title, int detail) {
        runOnUiThread(() -> {
            statusPanel.setVisibility(View.VISIBLE);
            statusTitle.setText(title);
            statusDetail.setText(detail);
            progressBar.setVisibility(View.VISIBLE);
            retryButton.setVisibility(View.GONE);
            photoButton.setEnabled(false);
            bottomHint.setVisibility(activeUsbDevice == null ? View.VISIBLE : View.GONE);
        });
    }

    private void showError(int title, int detail) {
        runOnUiThread(() -> {
            statusPanel.setVisibility(View.VISIBLE);
            statusTitle.setText(title);
            statusDetail.setText(detail);
            progressBar.setVisibility(View.GONE);
            retryButton.setVisibility(View.VISIBLE);
            photoButton.setEnabled(false);
            bottomHint.setVisibility(activeUsbDevice == null ? View.VISIBLE : View.GONE);
            retryButton.requestFocus();
        });
    }

    private void updateUsbBadge(UsbDevice device) {
        runOnUiThread(() -> {
            String name = device.getProductName();
            if (name == null || name.trim().isEmpty()) {
                name = String.format(Locale.US, "USB %04X:%04X",
                        device.getVendorId(), device.getProductId());
            }
            usbBadge.setText(getString(R.string.usb_connected_name, name));
        });
    }

    private void registerUsbReceiver() {
        if (receiverRegistered) {
            return;
        }
        IntentFilter filter = new IntentFilter(ACTION_USB_PERMISSION);
        filter.addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED);
        filter.addAction(UsbManager.ACTION_USB_DEVICE_DETACHED);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(usbReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(usbReceiver, filter);
        }
        receiverRegistered = true;
    }

    private void unregisterUsbReceiver() {
        if (receiverRegistered) {
            unregisterReceiver(usbReceiver);
            receiverRegistered = false;
        }
    }

    @SuppressWarnings("deprecation")
    private static UsbDevice usbDeviceExtra(Intent intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice.class);
        }
        return intent.getParcelableExtra(UsbManager.EXTRA_DEVICE);
    }

    private void startCameraThread() {
        if (cameraThread != null) {
            return;
        }
        cameraThread = new HandlerThread("OpenCamaraTV-Camera");
        cameraThread.start();
        cameraHandler = new Handler(cameraThread.getLooper());
    }

    private void stopCameraThread() {
        if (cameraThread == null) {
            return;
        }
        cameraThread.quitSafely();
        try {
            cameraThread.join();
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
        }
        cameraThread = null;
        cameraHandler = null;
    }

    @SuppressWarnings("deprecation")
    private void enterImmersiveMode() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
    }
}
