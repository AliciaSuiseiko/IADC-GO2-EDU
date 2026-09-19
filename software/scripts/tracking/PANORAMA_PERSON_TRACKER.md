# Panoramic Person Tracker MVP

The original node below is retained as a multi-person tracking-by-detection
control. ByteTrack is supported and remains useful for that control, but its
continuity is bounded by detector recall. The intended person-following path is
now single-object tracking (SOT):

```text
first-frame box/click/reference image
  -> target-centered viewport matched to the panorama projection
  -> modern perspective SOT model
  -> map the result back to spherical bearing/elevation
  -> angular motion filter and confidence state
  -> mask-gated DAP/LiDAR depth
  -> metric target state for the planner
```

The model-independent implementation is `panorama_sot_core.py`. It provides ERP
and cylindrical-strip viewport projection across the panorama seam, inverse target coordinates,
`VISIBLE/UNCERTAIN/LOST` search policy, circular angular prediction, and robust
mask-based depth statistics. ODTrack/SAM2 adapters should consume this module;
the existing ByteTrack/BoT-SORT node remains available for MOT comparisons.

The first ODTrack adapter is `run_panorama_odtrack.py`. It keeps the upstream
ODTrack network and checkpoint unchanged, but runs it on a target-centered
perspective viewport and writes the result back as spherical bearing, elevation,
and angular extent. `evaluate_panorama_sot.py` evaluates this representation with
circular horizontal geometry, so a prediction crossing the ERP seam is not treated
as a discontinuous jump.

## Verified baseline

The official ODTrack Base full-data checkpoint was evaluated on QuadTrack using an
RTX 4090:

- Sequence 0015, target 2, first 100 frames: 41.2 tracker FPS, mean circular IoU
  0.582, IoU >= 0.5 on 99% of frames, and 8.0 px mean center error.
- Sequence 0017, target 4, first 300 frames: 43.7 tracker FPS, mean circular IoU
  0.432 and 131.1 px mean center error. Visual inspection shows an identity switch
  when two similar people intersect around frames 150-175, followed by drift near
  the panorama boundary.

Those first runs incorrectly treated QuadTrack's `2048x480` cylindrical-style
panorama strip as a full-height equirectangular image. That mapping stretched the
person vertically and caused the apparent tracker and detector failure.

The corrected cylindrical viewport was then evaluated on all 600 frames of
QuadTrack sequence 0017, target 4. It achieved mean circular IoU `0.836`, IoU >=
0.5 on `99.67%` of frames, `8.49 px` mean center error, `92.33%` precision at 20
px, and `0.829 deg` mean bearing error. ODTrack alone ran at `36.2 FPS`; the
complete path with YOLO11n and OSNet checks every five frames ran at `15.3 FPS`.
The target remained correct across similar-person intersections and the circular
image seam. No detector-based correction was needed on this sequence.

The resulting baseline is deliberately small:

```text
cylindrical target-centred viewport
  -> ODTrack every frame
  -> low-frequency YOLO11n candidate detection
  -> OSNet identity/motion consistency gate
  -> correction only when external evidence clearly beats the SOT state
```

This is a reliable offline baseline on one complete difficult target sequence,
not yet a production claim across all scenes or the X5 live stream. The X5's
actual stitched projection and vertical angular mapping must be calibrated before
choosing the ERP or cylindrical adapter. SAM masks and metric depth belong after
identity is stable; they should refine target geometry and 3D state rather than
select identity.

This node provides the perception output needed before adding a following planner. It
does not publish velocity commands or invoke the Unitree controller.

## Live X5 projection and deployment result

The default live path is X5 Webcam/UVC mode. It was verified on Jetson as USB
device `2e1a:0005`, exposing an in-camera stitched and stabilized `2880x1440`
MJPEG ERP stream at 30 FPS:

```text
X5 Webcam/UVC 2880x1440@30
  -> compressed-stream rate limit
  -> decode and resize to 1920x960@10
  -> /camera/image
  -> local panoramic SOT frontend
```

The saved raw frame and ROS image are geometrically correct 2:1 panoramas. The
local path uses `/camera/image/compressed` between the C++ camera node and Python
tracker to avoid serializing a 5.5 MB BGR message each frame. It publishes
9.99-10.17 FPS and the tracker receives 9.986 FPS while uninitialized.

With a real distant-person bbox initialized, the complete ODTrack Base + YOLO +
OSNet path remained `VISIBLE` with identity similarity 0.92 and ODTrack response
0.83. It reached 6.10 FPS and 346.5 ms p95 processing latency with the default
check intervals. Relaxing YOLO and ReID checks improved this only to 6.74 FPS
and 278.0 ms p95. This isolates the remaining deployment bottleneck to the
PyTorch ODTrack Base path; LiteTrack/SUTrack and TensorRT are the next runtime
comparisons.

The CameraSDK path has two relevant controls, but neither supplies the required
stitched panorama on the tested Jetson preview path:

- `EnableInCameraStitching(true)` succeeds but the decoded preview remains two
  fisheye circles.
- `using_lrv=true` produces `1024x512` at approximately 9-10 FPS, but it is also
  dual-fisheye.

The x86 MediaSDK path is retained only as a slower reference/fallback:

```text
Jetson CameraSDK encoded stream
  -> x86-64 MediaSDK RealTimeStitcher on RTX 4090
  -> 1920x960 ERP at approximately 4.5 FPS
```

Returning those complete frames through the SSH tunnel was bandwidth-bound at
approximately 1.3 FPS, so it is not the default live deployment.

## Long-term recovery and auxiliary perception

The current long-term node uses a spherical constant-velocity Kalman state,
rather than a planar pixel extrapolation. During a short occlusion it predicts
bearing and elevation and exposes the growing covariance. Once the target is
lost, candidate selection combines immutable-anchor ReID, a bounded identity
gallery, spherical motion likelihood, target size consistency, and detector
confidence.

On twelve real QuadTrack annotation gaps, a YOLO26n recovery scan found no
successful target candidates. A server-side YOLO11x 1280-pixel two-stage scan
recovered three events. The unresolved cases are dominated by people as small
as 15 by 25 pixels. This is a detector proposal-recall limit; relaxing ReID or
Kalman gates cannot repair a missing candidate.

SAM2 mask refinement is event-triggered at initialization or reacquisition. It
publishes `/tracking/target_mask_refined` and handles ERP seam-crossing boxes by
rolling the panorama before inference. Warmed Jetson latency is approximately
235-265 ms, so it is not part of the per-frame loop.

DAP depth runs asynchronously on the RTX 4090. Only its input branch is resized
to 1024 by 512; the SOT input remains 1920 by 960. The measured server inference
time is 106-111 ms and Jetson-to-server round trip is 228-246 ms. The output is
relative depth and is explicitly labelled `depth_is_metric=false`.

## Pipeline

```text
/camera/image (equirectangular panorama)
  -> YOLO person detection
  -> Ultralytics BoT-SORT (ByteTrack fallback)
  -> seam-aware stable ID mapping
  -> person tracks, selected target state, annotated image
```

The seam mapper exposes one stable ID when a planar tracker changes its raw ID while
the person crosses the left/right boundary of an equirectangular image. It also
reports spherical azimuth and elevation instead of treating the panorama as a normal
perspective image. Before inference, the image is circularly shifted so the robot's
forward direction is fixed at image center and corresponds to `0 deg` bearing.

## Jetson launch

```bash
~/lianaiwei/tracking_deployment/scripts/run_panorama_person_tracker_jetson.sh
```

Optional environment variables:

```bash
export PERSON_TRACKER_MODEL=~/lianaiwei/path/to/yolo11n.pt
export PERSON_TRACKER_DEVICE=0
export PERSON_TRACKER_IMAGE_SIZE=960
export PERSON_TRACKER_PROCESS_EVERY_N=1
export PERSON_TRACKER_TARGET_LOST_FRAMES=30
export PERSON_TRACKER_BODY_FORWARD_OFFSET_DEG=0
```

`PERSON_TRACKER_BODY_FORWARD_OFFSET_DEG` is the azimuth of the robot's forward
direction in the raw X5 panorama. For example, use `90` when forward appears one
quarter image-width to the right of center. Calibrate this once after the camera mount
is fixed.

## Topics

Input:

- `/camera/image` (`sensor_msgs/Image`): X5 equirectangular image.
- `/tracking/select_target` (`std_msgs/String`): stable integer ID, or `reset` to
  select the largest visible person again.

Output:

- `/tracking/person_tracks` (`std_msgs/String`): JSON list containing bounding box,
  confidence, raw tracker ID, stable ID, spherical bearing/elevation and angular
  velocity.
- `/tracking/target_state` (`std_msgs/String`): JSON state `UNINITIALIZED`, `VISIBLE`,
  `PREDICTED` or `LOST`.
- `/tracking/annotated_image` (`sensor_msgs/Image`): visualization only.

Example target selection:

```bash
ros2 topic pub --once /tracking/select_target std_msgs/msg/String "{data: '2'}"
ros2 topic pub --once /tracking/select_target std_msgs/msg/String "{data: 'reset'}"
```

## Current boundary

The node estimates angular target state only. Metric 3D position requires calibrated
X5-to-Mid-360 projection or panoramic depth. Target appearance prototypes, learned
occlusion recovery, waypoint generation and robot following are separate downstream
stages.
