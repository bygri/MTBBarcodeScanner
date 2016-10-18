import UIKit
import AVFoundation


public typealias MetaDataObjectType = String

public enum MTBCamera {
  case back, front
}

public enum MTBTorchMode {
  case off, on, auto
}

let errorDomain = "MTBBarcodeScannerError"
public enum MTBBarcodeScannerError: Int, Error {
  case stillImageCaptureInProgress = 1000
  case sessionIsClosed = 1001
  case cameraIsNotPresent = 1002
  case scanningIsProhibited = 1003
  case noMetaDataTypesRequested = 1004
  case invalidMetaDataTypesRequested = 1005
  case scanningWithoutResultBlock = 1006
}

let centerFocalPointOfInterest = CGPoint(x: 0.5, y: 0.5)
let defaultRectOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1) // Default rectOfInterest for AVCaptureMetadataOutput

public class MTBBarcodeScanner: NSObject, AVCaptureMetadataOutputObjectsDelegate {
  
  /**
   *  Set which camera to use. See MTBCamera for options.
   */
  public var camera: MTBCamera = .back
  
  public func setCamera(_ camera: MTBCamera) throws {
    if let session = session, isScanning && camera != self.camera {
      let captureDevice = try newCaptureDevice(with: camera)
      let input = try deviceInput(for: captureDevice)
      try setDeviceInput(input, session: session)
    }
    self.camera = camera
  }
  
  /**
   *  Control the torch on the device, if present.
   */
  public var torchMode: MTBTorchMode = .off {
    didSet {
      try? updateTorchModeForCurrentSettings()
    }
  }
  
  /**
   *  Allow the user to tap the previewView to focus a specific area.
   *  Defaults to YES.
   */
  public var allowTapToFocus: Bool = true
  
  /**
   *  If set, only barcodes inside this area will be scanned.
   */
  public var scanRect: CGRect? {
    didSet {
      guard let rect = scanRect else {
        return
      }
      if rect.isEmpty {
        // TODO:
        //      NSAssert(!CGRectIsEmpty(scanRect), @"Unable to set an empty rectangle as the scanRect of MTBBarcodeScanner");
      }
      
      refreshVideoOrientation()
      
      captureOutput?.rectOfInterest = capturePreviewLayer?.metadataOutputRectOfInterest(for: rect) ?? defaultRectOfInterest
    }
  }
  
  /**
   *  Layer used to present the camera input. If the previewView
   *  does not use auto layout, it may be necessary to adjust the layers frame.
   */
  public var previewLayer: CALayer? {
    return capturePreviewLayer
  }
  
  /*!
   @property didStartScanningBlock
   @abstract
   Optional callback block that's called when the scanner finished initializing.
   
   @discussion
   Optional callback that will be called when the scanner is initialized and the view
   is presented on the screen. This is useful for presenting an activity indicator
   while the scanner is initializing.
   */
  public var didStartScanningBlock: (() -> Void)?
  
  /*!
   @property didTapToFocusBlock
   @abstract
   Block that's called when the user taps the screen to focus the camera. If allowsTapToFocus
   is set to NO, this will never be called.
   */
  public var didTapToFocusBlock: ((_ point: CGPoint) -> Void)?
  
  /*!
   @property resultBlock
   @abstract
   Block that's called for every barcode captured. Returns an array of AVMetadataMachineReadableCodeObjects.
   
   @discussion
   The resultBlock is called once for every frame that at least one valid barcode is found.
   The returned array consists of AVMetadataMachineReadableCodeObject objects.
   This block is automatically set when you call startScanningWithResultBlock:
   */
  public var resultBlock: ((_ codes: [AVMetadataMachineReadableCodeObject]) -> Void)?
  
  // MARK: Lifecycle
  
  /**
   *  Initialize a scanner that will feed the camera input
   *  into the given UIView.
   *
   *  @param previewView View that will be overlayed with the live feed from the camera input.
   *
   *  @return An instance of MTBBarcodeScanner
   */
  public init(with previewView: UIView) {
    self.previewView = previewView
    self.metaDataObjectTypes = self.defaultMetaDataObjectTypes
    super.init()
    addRotationObserver()
  }
  
  /**
   *  Initialize a scanner that will feed the camera input
   *  into the given UIView. Only codes with a type given in
   *  the metaDataObjectTypes array will be reported to the result
   *  block when scanning is started using startScanningWithResultBlock:
   *
   *  @see startScanningWithResultBlock:
   *
   *  @param metaDataObjectTypes Array of AVMetadataObjectTypes to scan for. Only codes with types given in this array will be reported to the resultBlock.
   *  @param previewView View that will be overlayed with the live feed from the camera input.
   *
   *  @return An instance of MTBBarcodeScanner
   */
  public convenience init(types metaDataObjectTypes: [MetaDataObjectType], with previewView: UIView) throws {
    guard metaDataObjectTypes.count > 0 else {
      throw MTBBarcodeScannerError.noMetaDataTypesRequested
    }
    guard metaDataObjectTypes.index(where: { $0 == AVMetadataObjectTypeFace }) == nil else {
      throw MTBBarcodeScannerError.invalidMetaDataTypesRequested
    }
    self.init(with: previewView)
    self.metaDataObjectTypes = metaDataObjectTypes
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  // MARK: Scanning
  
  /**
   *  Returns whether the camera exists in this device.
   *
   *  @return YES if the device has a camera.
   */
  public static var cameraIsPresent: Bool {
    return AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeVideo) != nil
  }
  
  /**
   *  Returns whether scanning is prohibited by the user of the device.
   *
   *  @return YES if the user has prohibited access to (or is prohibited from accessing) the camera.
   */
  public static var scanningIsProhibited: Bool {
    switch AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo) {
    case .denied, .restricted:
      return true
    default:
      return false
    }
  }
  
  /**
   *  Request permission to access the camera on the device.
   *
   *  The success block will return YES if the user granted permission, has granted permission in the past, or if the device is running iOS 7.
   *  The success block will return NO if the user denied permission, is restricted from the camera, or if there is no camera present.
   */
  public static func requestCameraPermission(successBlock: @escaping (Bool) -> Void) {
    guard cameraIsPresent else {
      successBlock(false)
      return
    }
    switch AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo) {
    case .authorized:
      successBlock(true)
    case .denied, .restricted:
      successBlock(false)
    case .notDetermined:
      AVCaptureDevice.requestAccess(forMediaType: AVMediaTypeVideo) { granted in
        DispatchQueue.main.async {
          successBlock(granted)
        }
      }
    }
  }
  
  /**
   *  Start scanning for barcodes. The camera input will be added as a sublayer
   *  to the UIView given for previewView during initialization.
   *
   *  This method assumes you have already set the `resultBlock` property directly.
   *
   *  @param error Error supplied if the scanning could not start.
   */
  public func startScanning() throws {
    guard let resultBlock = resultBlock else {
      throw MTBBarcodeScannerError.scanningWithoutResultBlock
    }
    try startScanning(resultBlock: resultBlock)
  }
  
  /**
   *  Start scanning for barcodes. The camera input will be added as a sublayer
   *  to the UIView given for previewView during initialization.
   *
   *  @param resultBlock Callback block for captured codes. If the scanner was instantiated with initWithMetadataObjectTypes:previewView, only codes with a type given in metaDataObjectTypes will be reported.
   *  @param error Error supplied if the scanning could not start.
   */
  public func startScanning(resultBlock: @escaping (_ codes: [AVMetadataMachineReadableCodeObject]) -> Void) throws {
    guard MTBBarcodeScanner.cameraIsPresent else {
      throw MTBBarcodeScannerError.cameraIsNotPresent
    }
    guard MTBBarcodeScanner.scanningIsProhibited == false else {
      throw MTBBarcodeScannerError.scanningIsProhibited
    }
    // Configure the session
    if (!hasExistingSession) {
      captureDevice = try newCaptureDevice(with: camera)
      session = try newSession(with: captureDevice!)
    }
    guard let capturePreviewLayer = capturePreviewLayer else {
      return
    }
    // Configure the rect of interest
    captureOutput?.rectOfInterest = rectOfInterest(from: scanRect)
    // Configure the preview layer
    capturePreviewLayer.cornerRadius = previewView.layer.cornerRadius
    previewView.layer.insertSublayer(capturePreviewLayer, at: 0) // Insert below all other views
    refreshVideoOrientation()
    // Configure 'tap to focus' functionality
    configureTapToFocus()
    self.resultBlock = resultBlock
    // Start the session after all configurations
    session?.startRunning()
    // Call that block now that we've started scanning
    didStartScanningBlock?()
  }
  
  /**
   *  Stop scanning for barcodes. The live feed from the camera will be removed as a sublayer from the previewView given during initialization.
   */
  public func stopScanning() {
    if hasExistingSession {
      hasExistingSession = false
      // Turn the torch off
      torchMode = .off
      // Remove the preview layer
      capturePreviewLayer?.removeFromSuperlayer()
      // Stop recognizing taps for the 'Tap to Focus' feature
      stopRecognizingTaps()
      DispatchQueue.global(qos: .default).async {
        // When we're finished scanning, reset the settings for the camera
        // to their original states
        try? self.removeDeviceInput()
        if let outputs = self.session?.outputs as? [AVCaptureOutput] {
          outputs.forEach {
            self.session?.removeOutput($0)
          }
        }
        self.session?.stopRunning()
        self.session = nil
        self.resultBlock = nil
        self.capturePreviewLayer = nil
      }
    }
  }
  
  /**
   *  Whether the scanner is currently scanning for barcodes
   *
   *  @return YES if the scanner is currently scanning for barcodes
   */
  public var isScanning: Bool {
    return session?.isRunning ?? false
  }
  
  /**
   *  If using the front camera, switch to the back, or visa-versa.
   *  If this method is called when isScanning=NO, it has no effect
   *
   *  If the opposite camera is not available, this method will do nothing.
   */
  //  public func flipCamera() {
  //    try? flipCamera()
  //  }
  
  /**
   *  If using the front camera, switch to the back, or visa-versa.
   *  If this method is called when isScanning=NO, it has no effect
   *
   *  If the opposite camera is not available, the error property will explain the error.
   */
  public func flipCamera() throws {
    if (isScanning) {
      if camera == .front {
        try setCamera(.back)
      } else {
        try setCamera(.front)
      }
    }
  }
  
  /**
   *  Return a BOOL value that specifies whether the current capture device has a torch.
   *
   *  @return YES if the the current capture device has a torch.
   */
  public var hasTorch: Bool {
    guard
      let captureDevice = try? newCaptureDevice(with: camera),
      let input = try? deviceInput(for: captureDevice)
      else {
        return false
    }
    return input.device.hasTorch
  }
  
  /**
   *  Toggle the torch from on to off, or off to on.
   *  If the torch was previously set to Auto, the torch will turn on.
   *  If the device does not support a torch, calling this method will have no effect.
   *  To set the torch to on/off/auto directly, set the `torchMode` property.
   */
  public func toggleTorch() {
    if torchMode == .auto || torchMode == .off {
      torchMode = .on
    } else {
      torchMode = .off
    }
  }
  
  /**
   *  Freeze capture keeping the last frame on previewView.
   *  If this method is called before startScanning, it has no effect.
   */
  public func freezeCapture() {
    capturePreviewLayer?.connection.isEnabled = false
    
    if hasExistingSession {
      session?.stopRunning()
    }
  }
  
  /**
   *  Unfreeze a frozen capture
   */
  public func unfreezeCapture() throws {
    guard
      let capturePreviewLayer = capturePreviewLayer,
      let currentCaptureDeviceInput = currentCaptureDeviceInput,
      let session = session
      else {
        return
    }
    capturePreviewLayer.connection.isEnabled = true
    
    if hasExistingSession && !session.isRunning {
      try setDeviceInput(currentCaptureDeviceInput, session: session)
      session.startRunning()
    }
  }
  
  /**
   *  Captures a still image of the current camera feed
   */
  public func captureStillImage(captureBlock: ((_ image: UIImage?, _ error: Error?) -> Void)?) {
    if isCapturingStillImage {
      captureBlock?(nil, MTBBarcodeScannerError.stillImageCaptureInProgress)
      return
    }
    guard let stillImageOutput = stillImageOutput else {
      return
    }
    
    guard let stillConnection = stillImageOutput.connection(withMediaType: AVMediaTypeVideo) else {
      captureBlock?(nil, MTBBarcodeScannerError.sessionIsClosed)
      return
    }
    
    stillImageOutput.captureStillImageAsynchronously(from: stillConnection) { imageDataSampleBuffer, error in
      if let error = error {
        captureBlock?(nil, error)
      }
      
      if
        let jpegData = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(imageDataSampleBuffer),
        let image = UIImage(data: jpegData)
      {
        captureBlock?(image, nil)
      } else {
        captureBlock?(nil, nil)
      }
    }
  }
  
  /**
   *  Determine if currently capturing a still image
   */
  public var isCapturingStillImage: Bool {
    return self.stillImageOutput?.isCapturingStillImage ?? false
  }
  
  // MARK: Private properties
  
  /*!
   @property session
   @abstract
   The capture session used for scanning barcodes.
   */
  var session: AVCaptureSession?
  
  /*!
   @property captureDevice
   @abstract
   Represents the physical device that is used for scanning barcodes.
   */
  var captureDevice: AVCaptureDevice?
  
  /*!
   @property capturePreviewLayer
   @abstract
   The layer used to view the camera input. This layer is added to the
   previewView when scanning starts.
   */
  var capturePreviewLayer: AVCaptureVideoPreviewLayer?
  
  /*!
   @property currentCaptureDeviceInput
   @abstract
   The current capture device input for capturing video. This is used
   to reset the camera to its initial properties when scanning stops.
   */
  var currentCaptureDeviceInput: AVCaptureDeviceInput?
  
  /*
   @property captureDeviceOnput
   @abstract
   The capture device output for capturing video.
   */
  var captureOutput: AVCaptureMetadataOutput?
  
  /*!
   @property metaDataObjectTypes
   @abstract
   The MetaDataObjectTypes to look for in the scanning session.
   
   @discussion
   Only objects with a MetaDataObjectType found in this array will be
   reported to the result block.
   */
  var metaDataObjectTypes: [MetaDataObjectType]
  
  /*!
   @property previewView
   @abstract
   The view used to preview the camera input.
   
   @discussion
   The AVCaptureVideoPreviewLayer is added to this view to preview the
   camera input when scanning starts. When scanning stops, the layer is
   removed.
   */
  weak var previewView: UIView!
  
  /*!
   @property hasExistingSession
   @abstract
   BOOL that is set to YES when a new valid session is created and set to NO when stopScanning
   is called.
   
   @discussion
   stopScanning now discards the session asynchronously and hasExistingSession is set to NO before
   that block is called. If startScanning is called while the discard block is still in progress
   hasExistingSession will be NO so we can create a new session instead of attempting to use
   the session that is being discarded.
   */
  var hasExistingSession: Bool = false
  
  /*!
   @property initialAutoFocusRangeRestriction
   @abstract
   The auto focus range restriction the AVCaptureDevice was initially configured for when scanning started.
   
   @discussion
   When startScanning is called, the auto focus range restriction of the default AVCaptureDevice
   is stored. When stopScanning is called, the AVCaptureDevice is reset to the initial range restriction
   to prevent a bug in the AVFoundation framework.
   */
  var initialAutoFocusRangeRestriction: AVCaptureAutoFocusRangeRestriction?
  
  /*!
   @property initialFocusPoint
   @abstract
   The focus point the AVCaptureDevice was initially configured for when scanning started.
   
   @discussion
   When startScanning is called, the focus point of the default AVCaptureDevice
   is stored. When stopScanning is called, the AVCaptureDevice is reset to the initial focal point
   to prevent a bug in the AVFoundation framework.
   */
  var initialFocusPoint: CGPoint?
  
  /*!
   @property stillImageOutput
   @abstract
   Used for still image capture
   */
  var stillImageOutput: AVCaptureStillImageOutput?
  
  /*!
   @property gestureRecognizer
   @abstract
   If allowTapToFocus is set to YES, this gesture recognizer is added to the `previewView`
   when scanning starts. When the user taps the view, the `focusPointOfInterest` will change
   to the location the user tapped.
   */
  var gestureRecognizer: UITapGestureRecognizer?
  
  // MARK: - Grab-bag from here on out
  
  // MARK: Tap to Focus
  
  func configureTapToFocus() {
    guard allowTapToFocus else {
      return
    }
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(focusTapped(tapGesture:)))
    previewView?.addGestureRecognizer(tapGesture)
    gestureRecognizer = tapGesture
  }
  
  func focusTapped(tapGesture: UITapGestureRecognizer) {
    let tapPoint = tapGesture.location(in: tapGesture.view)
    guard
      let devicePoint = capturePreviewLayer?.captureDevicePointOfInterest(for: tapPoint),
      let device = captureDevice
      else {
        return
    }
    
    let lockResult = try? device.lockForConfiguration()
    if lockResult != nil {
      if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusPointOfInterest = devicePoint
        device.focusMode = .continuousAutoFocus
      }
      device.unlockForConfiguration()
    }
    
    didTapToFocusBlock?(tapPoint)
  }
  
  func stopRecognizingTaps() {
    if let recognizer = gestureRecognizer {
      previewView?.removeGestureRecognizer(recognizer)
    }
  }
  
  // MARK: AVCaptureMetadataOutputObjects Delegate
  
  public func capture(output captureOutput: AVCaptureOutput!, didOutput metadataObjects: [Any]!, from connection: AVCaptureConnection!) {
    guard
      let resultBlock = resultBlock,
      let objects = metadataObjects as? [AVMetadataMachineReadableCodeObject]
      else {
        return
    }
    
    let codes = objects.flatMap {
      capturePreviewLayer?.transformedMetadataObject(for: $0) as? AVMetadataMachineReadableCodeObject
    }
    
    resultBlock(codes)
  }
  
  // MARK: Rotation
  
  func handleDeviceOrientationDidChangeNotification(notification: NSNotification) {
    refreshVideoOrientation()
  }
  
  func refreshVideoOrientation() {
    guard let capturePreviewLayer = capturePreviewLayer else {
      return
    }
    let orientation = UIApplication.shared.statusBarOrientation
    capturePreviewLayer.frame = previewView!.bounds
    if capturePreviewLayer.connection.isVideoOrientationSupported {
      capturePreviewLayer.connection.videoOrientation = captureOrientation(forInterfaceOrientation: orientation)
    }
  }
  
  func captureOrientation(forInterfaceOrientation interfaceOrientation: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
    switch interfaceOrientation {
    case .portrait:
      return .portrait
    case .portraitUpsideDown:
      return .portraitUpsideDown
    case .landscapeLeft:
      return .landscapeLeft
    case .landscapeRight:
      return .landscapeRight
    default:
      return .portrait
    }
  }
  
  // MARK: Session Configuration
  
  func newSession(with captureDevice: AVCaptureDevice) throws -> AVCaptureSession {
    let input = try deviceInput(for: captureDevice)
    
    let newSession = AVCaptureSession()
    try setDeviceInput(input, session: newSession)
    
    // Set an optimized preset for barcode scanning
    newSession.canSetSessionPreset(AVCaptureSessionPresetHigh)
    
    let captureOutput = AVCaptureMetadataOutput()
    captureOutput.setMetadataObjectsDelegate(self, queue: .main)
    
    newSession.addOutput(captureOutput)
    captureOutput.metadataObjectTypes = metaDataObjectTypes
    
    // Still image capture configuration
    let stillImageOutput = AVCaptureStillImageOutput()
    stillImageOutput.outputSettings = [AVVideoCodecKey: AVVideoCodecJPEG]
    
    if stillImageOutput.isStillImageStabilizationSupported {
      stillImageOutput.automaticallyEnablesStillImageStabilizationWhenAvailable = true
    }
    
    //    if stillImageOutput.responds(to: Selector(isHighResolutionStillImageOutputEnabled)) {
    stillImageOutput.isHighResolutionStillImageOutputEnabled = true
    //    }
    newSession.addOutput(stillImageOutput)
    
    captureOutput.rectOfInterest = rectOfInterest(from: scanRect)
    
    capturePreviewLayer = nil
    capturePreviewLayer = AVCaptureVideoPreviewLayer(session: newSession)
    capturePreviewLayer!.videoGravity = AVLayerVideoGravityResizeAspectFill
    capturePreviewLayer!.frame = previewView.bounds
    
    newSession.commitConfiguration()
    self.captureOutput = captureOutput
    self.stillImageOutput = stillImageOutput
    return newSession
  }
  
  func deviceInput(for captureDevice: AVCaptureDevice) throws -> AVCaptureDeviceInput {
    let input = try AVCaptureDeviceInput.init(device: captureDevice)
    return input
  }
  
  func newCaptureDevice(with camera: MTBCamera) throws -> AVCaptureDevice {
    let videoDevices = AVCaptureDevice.devices(withMediaType: AVMediaTypeVideo) as! [AVCaptureDevice]
    let position = devicePosition(for: camera)
    // If the front camera is not available, use the back camera
    guard let newCaptureDevice = videoDevices.filter({ $0.position == position }).first ?? AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeVideo) else {
      throw NSError(domain: errorDomain, code: 6, userInfo: nil)
    }
    
    // Using AVCaptureFocusModeContinuousAutoFocus helps improve scan times
    try newCaptureDevice.lockForConfiguration()
    if newCaptureDevice.isFocusModeSupported(.continuousAutoFocus) {
      newCaptureDevice.focusMode = .continuousAutoFocus
    }
    newCaptureDevice.unlockForConfiguration()
    
    return newCaptureDevice
  }
  
  func devicePosition(for camera: MTBCamera) -> AVCaptureDevicePosition {
    switch camera {
    case .front:
      return .front
    case .back:
      return .back
    }
  }
  
  // MARK: Default Values
  
  let defaultMetaDataObjectTypes: [MetaDataObjectType] = {
    var types = [
      AVMetadataObjectTypeQRCode,
      AVMetadataObjectTypeUPCECode,
      AVMetadataObjectTypeCode39Code,
      AVMetadataObjectTypeCode39Mod43Code,
      AVMetadataObjectTypeEAN13Code,
      AVMetadataObjectTypeEAN8Code,
      AVMetadataObjectTypeCode93Code,
      AVMetadataObjectTypeCode128Code,
      AVMetadataObjectTypePDF417Code,
      AVMetadataObjectTypeAztecCode
    ]
    if floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_7_1 {
      types += [
        AVMetadataObjectTypeInterleaved2of5Code,
        AVMetadataObjectTypeITF14Code,
        AVMetadataObjectTypeDataMatrixCode
      ]
    }
    return types
  }()
  
  // MARK: Helper methods
  
  func addRotationObserver() {
    NotificationCenter.default.addObserver(self, selector: #selector(handleDeviceOrientationDidChangeNotification(notification:)), name: .UIDeviceOrientationDidChange, object: nil)
  }
  
  func setDeviceInput(_ deviceInput: AVCaptureDeviceInput, session: AVCaptureSession) throws {
    try removeDeviceInput()
    
    currentCaptureDeviceInput = deviceInput
    
    try deviceInput.device.lockForConfiguration()
    
    // Prioritize the focus on objects near to the device
    if deviceInput.device.isAutoFocusRangeRestrictionSupported {
      initialAutoFocusRangeRestriction = deviceInput.device.autoFocusRangeRestriction
      deviceInput.device.autoFocusRangeRestriction = .near
    }
    
    // Focus on the center of the image
    if deviceInput.device.isFocusPointOfInterestSupported {
      initialFocusPoint = deviceInput.device.focusPointOfInterest
      deviceInput.device.focusPointOfInterest = centerFocalPointOfInterest
    }
    
    try updateTorchModeForCurrentSettings()
    
    deviceInput.device.unlockForConfiguration()
    
    session.addInput(deviceInput)
  }
  
  func removeDeviceInput() throws {
    // No need to remove the device input if it was never set
    guard let deviceInput = currentCaptureDeviceInput else {
      return
    }
    
    // Restore focus settings to the previously saved state
    try deviceInput.device.lockForConfiguration()
    if
      deviceInput.device.isAutoFocusRangeRestrictionSupported,
      let initialAutoFocusRangeRestriction = initialAutoFocusRangeRestriction
    {
      deviceInput.device.autoFocusRangeRestriction = initialAutoFocusRangeRestriction
    }
    
    if
      deviceInput.device.isFocusPointOfInterestSupported,
      let initialFocusPoint = initialFocusPoint
    {
      deviceInput.device.focusPointOfInterest = initialFocusPoint
    }
    
    deviceInput.device.unlockForConfiguration()
    
    session?.removeInput(deviceInput)
    currentCaptureDeviceInput = nil
  }
  
  // MARK: Torch Control
  
  func updateTorchModeForCurrentSettings() throws {
    guard let backCamera = AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeVideo) else {
      return
    }
    if backCamera.isTorchAvailable && backCamera.isTorchModeSupported(.on) {
      try backCamera.lockForConfiguration()
      let mode = avTorchMode(for: torchMode)
      backCamera.torchMode = mode
      backCamera.unlockForConfiguration()
    }
  }
  
  func avTorchMode(for torchMode: MTBTorchMode) -> AVCaptureTorchMode {
    switch torchMode {
    case .on:
      return .on
    case .auto:
      return .auto
    default:
      return .off
    }
  }
  
  // MARK: Helper methods (again)
  
  func rectOfInterest(from scanRect: CGRect?) -> CGRect {
    if let scanRect = scanRect, scanRect.isEmpty == false {
      return capturePreviewLayer?.metadataOutputRectOfInterest(for: scanRect) ?? defaultRectOfInterest
    }
    return defaultRectOfInterest
  }
  
}
