# Glance 👀

A menu-bar app that watches which monitor you're looking at (via the webcam) and moves keyboard focus there.

## How it works

- **Tracking:** Apple's Vision framework measures head yaw and pitch, where your nose sits in your face, and where your pupils sit in your eyes, about 12 times a second. Video stays on your Mac.
- **Calibration:** a dot visits a 3×3 grid on each screen, edges included. Glance stores what your face looks like for each point and later matches live frames against those samples (k-nearest neighbours). Each signal is weighted by how well it separates *your* screens: stacked monitors lean on up/down movement, side-by-side ones on left/right.
- **Accuracy:** the menu shows an estimate for each screen. Each calibration point is checked against a model built without that point, so a low number really does mean that screen is hard to recognise.
- **Switching (default, *When I Start Typing*):** looking somewhere does nothing by itself. On the first keystroke after a pause, if you've been looking steadily at another screen, Glance holds your keys for about 70 ms, focuses the frontmost window on that screen, then sends the keys there. Keys typed mid-flow never switch, so you can read a reference on another monitor while you type.
- **Switching (*As Soon As I Look*):** focus follows your gaze once it rests on a screen long enough.
- **Guards:** it never switches just after a click or while a mouse button is held.

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
