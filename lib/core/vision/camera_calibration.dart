/// Computes the focal length in pixels for the camera using a single
/// measurement based on the pinhole camera model.
///
/// To calibrate, capture a photo of an object with known real-world height
/// positioned at a measured distance from the camera. Measure the object's
/// bounding box height in pixels from that same image, then compute the focal
/// length using this helper. Store the resulting value (for example in
/// `assets/config/calibration.json`) and reuse it for all subsequent
/// estimations.
double computeFocalPx({
  required double bboxHeightPx,
  required double knownDistanceM,
  required double realHeightM,
}) {
  return (bboxHeightPx * knownDistanceM) / realHeightM;
}
