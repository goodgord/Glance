# Glance 👀

A menu-bar app that watches which monitor you're looking at (via the webcam) and moves keyboard focus there.

## How it works

- **Tracking:** Apple's Vision framework measures head yaw and pitch, where your nose sits in your face, and where your pupils sit in your eyes, about 12 times a second. Video stays on your Mac.
- **Calibration:** a dot visits 5 spots on each screen. Glance stores what your face looks like for each one and later matches live frames against those samples (weighted k-nearest neighbours).
- **Switching:** once your gaze rests on a screen for long enough, Glance raises and focuses the frontmost window on that screen using the Accessibility API.
- **Guards:** it never switches while you're typing, just after a click, or while a mouse button is held.

## Build / run

```sh
./build.sh            # → build/Glance.app
./build.sh --install  # → /Applications/Glance.app
```

The first launch asks for **Camera** and **Accessibility** access. The calibration then runs on its own. If you rearrange monitors, recalibrate.

## Menu

- The number next to the eye is the screen you're looking at, counting left to right.
- **Responsiveness** sets how long you must look at a screen, and how long Glance waits after typing, before it switches.
- **Move Pointer Too** moves the mouse to the screen it switches to.
- **Camera** picks the camera if you have more than one, such as an external webcam or Continuity Camera.
