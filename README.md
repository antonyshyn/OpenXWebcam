<p align="center">
  <img src="openxwebcam.svg" width="160" alt="OpenXWebcam logo">
</p>

# OpenXWebcam

Open-source macOS app that turns a Fujifilm camera into a system webcam over USB.
A replacement for Fujifilm's "FUJIFILM X Webcam" app, which no longer works on current macOS.

## How it works

Fujifilm X cameras have no UVC webcam mode, so the video has to be pulled over
USB PTP. macOS's `ptpcamerad` normally holds the camera's USB interface; OpenXWebcam
takes it over and runs the Fuji live-view sequence itself:

```
camera ──USB/PTP──> menu bar app ──> CMIO camera extension ──> Zoom / Meet / OBS
                    (claims the interface, starts live view,
                     decodes the JPEG stream)
```

## Camera support

The live-view protocol is the same across modern X and GFX bodies. The app
adapts at runtime: it reads what the connected camera advertises and only
offers settings the camera actually has.

| Camera | Status |
| --- | --- |
| X-T30 | works, tested |
| X-T1, X-T2, X-T3, X-T4, X-T5, X-Pro2, X-Pro3, X-E3, X-H1, X-H2, X-S10, X100V, X-M5, GFX 50S, GFX 50R, GFX 100, GFX 100S, GFX 100 II | expected to work — same protocol, live view confirmed by the libgphoto2 project |
| X-H2S, X-E4, X-E5, X100VI, X-T30 II, X-S20, older X bodies | should work, unconfirmed |

Have an unconfirmed body? Try it and open an issue with the output of
"Copy Diagnostics" from the settings menu.

## Camera setup

- USB MODE: `X WEBCAM` (MENU → CONNECTION SETTING → USB MODE).
- Auto Power Off: OFF.
- Focus: the camera's own AF settings stay in charge while streaming. Set the
  focus switch to AF-C and turn on Face/Eye detection for hands-free focus;
  half-pressing the shutter refocuses too. Focus can't be driven over USB in
  webcam mode — the camera doesn't expose it.

## Troubleshooting

- Use a data-capable USB cable. Charge-only cables look like "no camera".
- Set Auto Power Off to OFF, or the camera drops off the bus mid-stream.
- After unplugging mid-session the X-T30 sometimes won't re-enumerate until
  you power it off and on with the cable connected, or replug the cable.
- The USB MOVIE SHOOTING modes don't connect to a computer at all (they're
  for gimbals and remotes). Use `X WEBCAM`.

## License

MIT — see [LICENSE](LICENSE).
