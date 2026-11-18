# Pano 360

A native iOS 27 app for capturing full 360°×180° photo spheres. It works like the
classic Street View / Photo Sphere capture flow:

1. The app opens on the camera. An orange **dot** marks where to point the phone first
   (straight ahead on the horizon). A fixed **aiming circle** sits in the middle of the screen.
2. Move the phone until the dot is inside the circle. When the phone is on target, upright
   and steady, the circle fills and the photo is taken automatically. You never press a shutter.
3. The photo is pinned into the live AR view at the exact spot it was taken, and the next
   dot appears. The next dot always overlaps what you have already captured. Off-screen
   dots get an arrow at the screen edge.
4. After the horizon ring, the upper ring, the zenith, the lower ring and the nadir are done,
   or when you tap **Done**, the photos are stitched on-device. The result opens in an
   interactive 360° viewer (drag or gyroscope, pinch to zoom). It is saved as an
   equirectangular JPEG with Google Photo Sphere (GPano) XMP metadata, so Google Photos,
   Facebook and similar apps show it as an interactive 360 photo. From the viewer you can
   share it or save it to Photos.

## Repository layout

| Path | What |
| --- | --- |
| `App/` | SwiftUI app: ARKit capture (`Capture/`), stitching job (`Stitching/`), gallery (`Library/`), Metal 360° viewer (`Viewer/`) |
| `Packages/PanoramaCore/` | Pure-Swift stitching engine, no Apple-only dependencies. Unit-tested on Linux and macOS |
| `project.yml` | XcodeGen project spec. The `.xcodeproj` is generated and not committed |
| `.github/workflows/ci.yml` | Engine tests (Linux) and an unsigned iOS build on the `xcode-27` runner |
| `.github/workflows/testflight.yml` | Archive, cloud-sign and upload to TestFlight |

## Stitching: what algorithm, and why

The reference for automatic panorama stitching is Brown & Lowe, *Automatic Panoramic
Image Stitching using Invariant Features* (IJCV 2007). It is the pipeline behind Hugin,
OpenCV's `Stitcher`, AutoStitch and the photo-sphere apps:
feature matching → rotation bundle adjustment → gain compensation → seam selection →
multi-band blending (Burt & Adelson 1983). Pano 360 implements that pipeline, with one
change that matters on a phone: **the sensors already give each photo's orientation.**

0. **Per-target exposure burst.** At every dot the app takes two full-resolution frames
   at the locked exposure and one −2 EV frame. `ShotMerger` aligns them (ARKit rotation
   homography plus a sub-pixel NCC shift), measures the real exposure ratios from the
   data, rejects ghosts (people moving) and motion-blurred frames, and combines them with
   **Mertens exposure fusion**. Lamps and windows keep their detail, noise averages out,
   and every shot gets the sharpest frame as its reference.
1. **Sensor-guided capture.** ARKit's visual-inertial tracking (`worldAlignment = .gravity`)
   gives every photo a camera-to-world rotation, usually accurate to under 1°, plus exact
   per-frame intrinsics. Photos come from `captureHighResolutionFrame` and are downscaled
   to 2048 px. Exposure, white balance and focus are locked after the first shot so all
   photos match. Focus stays automatic so near objects stay sharp.
2. **Pairwise registration in a common view.** For every pair the sensor poses say overlap,
   both photos are re-projected into one rectilinear view centred between them. The overlap
   is then already nearly aligned and free of perspective differences, so plain patch
   matching works well, without scale- or rotation-invariant descriptors.
   - A coarse-to-fine NCC search over a pyramid removes the remaining global offset.
   - Shi-Tomasi corners are taken from a 16×16 grid so matches spread across the overlap.
     They are matched by normalised cross-correlation, which ignores exposure differences,
     with sub-pixel parabola refinement.
   - A 3D rotation is fitted robustly (exhaustive 2-point RANSAC, then Gauss-Newton). The
     view is re-rendered with that correction and matched once more at a tighter tolerance.
3. **Global rotation bundle adjustment.** Levenberg-Marquardt over all photo rotations
   minimises the angular reprojection error of every correspondence, with a Huber loss.
   A weak prior towards the sensor pose fixes the gauge and keeps textureless photos
   (sky, ceilings) where ARKit put them. The horizon stays level because gravity is known.
4. **Vignetting + gain compensation.** A radial falloff V(r) = exp(a r² + b r⁴), shared
   by all photos, and per-photo log gains are solved jointly by linear least squares
   from overlapping samples. Then Brown & Lowe's per-image, per-channel gains.
5. **Parallax compensation on every iPhone.** Handheld capture never rotates exactly
   around the lens: turning your body moves the phone 10–40 cm, which shifts nearby
   objects by many degrees between shots. Each pixel is lifted to 3D with a metric depth
   map and re-projected from the panorama centre, the mean capture position
   (`Projector`). Depth is fused per photo (`DepthFusion`) from:
   - **LiDAR** `smoothedSceneDepth` on Pro models;
   - **ARKit's tracked feature points** (`rawFeaturePoints`), logged during capture;
   - **triangulated matches**: the phone's movement between shots is a stereo baseline,
     and points are triangulated with bundle-adjusted rotations (a two-pass BA);
   - **Depth Anything V2** (Apple's Core ML build, on the Neural Engine): dense
     relative depth, fitted per photo to the metric points via a robust 1/z = s·d + t.

   The capture UI also warns when the phone drifts more than 8 cm and blocks capture
   beyond 25 cm.
6. **Graph-cut seams** (Kwatra et al. 2003, Agarwala et al. 2004). Each panorama pixel
   is labelled with its source photo by minimizing data + seam costs with α-expansion
   (Boykov–Kolmogorov max-flow) on a 1536×768 grid. A seam between photos *a* and *b*
   costs |I_a − I_b| on both sides, so seams run where the photos agree and go around
   people, chairs and other parallax-affected objects instead of through them.
7. **Multi-band blending.** Five Laplacian pyramid bands are blended with the blurred
   seam masks: low frequencies blend over a wide area (no exposure steps) and high
   frequencies over a few pixels (no ghosting). Warped tiles are hole-filled with
   push-pull first, so the pyramid never sees artificial edges. Pyramids wrap around
   horizontally, so the ±180° seam is invisible.
8. **Output.** An equirectangular panorama, 8192×4096 on 8 GB devices, 6144×3072 on 6 GB
   and 4096×2048 otherwise, with GPano metadata.

Why not off-the-shelf OpenCV? Its stitcher is good, but it brings a large C++ binary, does
not use the free ARKit poses, and its feature matching is the step most likely to fail on
low-texture scenes. Using the sensor poses for initialisation and as a fallback makes this
pipeline more robust and much faster. Keeping it pure Swift makes it testable anywhere.

**Verification.** `PanoramaCoreTests` renders a synthetic full-sphere scene with the real
capture plan, randomised aiming errors, about 1° of simulated sensor noise and ±8%
exposure differences, then stitches it. Current results: 31 photos, mean rotation error
0.05° (down from about 3° before alignment), 2.2k correspondences over 95 pairs,
reprojection RMS 0.9 px, 34.6 dB PSNR against ground truth.

```sh
cd Packages/PanoramaCore && swift test -c release -Xswiftc -enable-testing
```

A second test renders a room with nearby objects, captured by a phone that sits 12 cm in
front of the user's turning axis, with LiDAR-like 64×48 depth maps:

| Pipeline | PSNR vs. ground truth | Rotation error |
| --- | --- | --- |
| Rotation-only (previous) | 16.7 dB | 4.6° (parallax absorbed as rotation error) |
| + graph-cut seams | 16.7 dB | 4.6° |
| + depth parallax compensation | **32.2 dB** | **0.02°** |

Without LiDAR, with only ARKit-like sparse points and a simulated monocular network
(unknown scale and shift per photo, plus noise):

| Depth source | PSNR |
| --- | --- |
| Triangulation only | 17.7 dB |
| + ARKit feature points | 27.7 dB |
| + monocular depth fitted to the points | **32.9 dB** (≈ LiDAR) |

Vignetting with a corner falloff to 58%: estimated to within 0.1%, 28.5 → 37.7 dB.
Burst fusion with lamps 10–15× brighter than the room: clipped pixels drop from 2339 to
880, close to the 665 that are clipped even in the darkest frame. A person walking
through one frame is rejected.

Possible future improvements: optical-flow deghosting, a lens-distortion term in bundle
adjustment, and Metal acceleration.

## Building locally

```sh
brew install xcodegen
scripts/fetch-models.sh   # optional: Depth Anything V2 Core ML model (~50 MB)
DEVELOPMENT_TEAM=ABCDE12345 BUILD_NUMBER=1 xcodegen generate
open Pano360.xcodeproj
```

Run it on a real iPhone; ARKit capture does not work in the Simulator.

## TestFlight via GitHub Actions

`.github/workflows/testflight.yml` runs on pushes to `main`, on `v*` tags and on manual
dispatch. It uses Xcode cloud-managed signing through an App Store Connect API key, so no
certificates or provisioning profiles need to be stored.

Repository **secrets**:

| Name | Value |
| --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID (App Store Connect → Users and Access → Integrations) |
| `APP_STORE_CONNECT_API_KEY` | Contents of `AuthKey_XXXX.p8`, raw or base64 |
| `APPLE_TEAM_ID` | 10-character team ID |

The bundle ID `com.moritzwolf.pano360` is set in `project.yml`.

Requirements:
- The API key needs the **Admin** role. Cloud-managed signing has to create the
  distribution certificate, and other roles cannot.
- An app record with the same bundle ID must exist in App Store Connect
  (My Apps → + → New App). The bundle ID itself is registered automatically on the
  first archive.
- Build numbers are `run_number.run_attempt`, so they always increase.
