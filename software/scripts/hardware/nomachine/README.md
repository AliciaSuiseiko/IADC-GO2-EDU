# NoMachine on Jetson

The Jetson uses NoMachine Free Edition to share one Linux desktop. A running
physical Xorg server with no monitor can produce a black session because
NoMachine sees Xorg and does not create its embedded display.

At boot, `nomachine-display-auto.service` configures NoMachine's documented
embedded-display fallback (`CreateDisplay 1`, owner `orin`, `1920x1080`),
starts the ordinary GDM desktop, and checks the real Xorg outputs for 30
seconds:

- A `DP-* connected` output keeps GDM and the auto-logged-in `orin` GNOME
  desktop. The monitor and NoMachine mirror the same desktop.
- With no connected output, it stops GDM and restarts NoMachine. The embedded
  display is created automatically for `orin`, without a client-side prompt,
  and provides a `1920x1080` GNOME desktop instead of a black physical Xorg
  session.

The monitor must be connected before boot for automatic local selection. If a
monitor is plugged in after headless mode has already been selected, switch to
`shared` or reboot.

Status:

```bash
~/lianaiwei/scripts/hardware/nomachine/nomachine-display-mode.sh status
```

No monitor attached:

```bash
~/lianaiwei/scripts/hardware/nomachine/nomachine-display-mode.sh headless
```

Physical monitor attached:

```bash
~/lianaiwei/scripts/hardware/nomachine/nomachine-display-mode.sh shared
```

`local` remains a backwards-compatible alias for `shared`.

On macOS, open the NoMachine in-session menu with `Command+Option+0`, then:

- Display: use `Scale to window`; avoid repeatedly changing the remote desktop
  resolution while RViz is running.
- Input: enable right-button and middle-button emulation for a trackpad.
- RViz Orbit view: left drag rotates, middle drag pans, right drag or scrolling
  zooms, `f` focuses the object under the pointer, and `z` resets the view.
