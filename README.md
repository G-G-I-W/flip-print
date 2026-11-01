# FlipPrint

Manual double-sided printing for printers without automatic duplex, such as the
Epson L3250. Android first; it also builds for iOS, Windows, macOS and Linux.

## How it talks to the printer
- **Wi-Fi printers (IPP):** FlipPrint finds the printer with mDNS (`_ipp._tcp`)
  and sends pages directly over **IPPS**, which is IPP over TLS on port 631. The
  L3250 rejects plain IPP with HTTP 426. Pages are rendered at 360 dpi and sent
  as **PWG raster**, the only open format the L3250 accepts. Live progress comes
  from `job-impressions-completed`.
- **Any other printer:** choose "Other printer (system dialog)" to print through
  Android's print dialog (Mopria, the Epson plug-in, etc.).

## Scanning
The L3250 has no eSCL/AirScan. It scans over **WSD (WS-Scan)** at
`http://<printer-ip>:80/WDP/SCAN` and returns a JPEG (100 or 300 dpi, colour or
greyscale). The Scan screen scans pages one by one into a PDF. You can save it,
share it, or "Print copies", which sends it through the duplex print flow.

## Using it
1. Select a PDF, then set copies, pages, paper size and orientation.
2. **Start Printing**: the odd pages of every copy print in one job.
3. Turn the stack over like a book page and load it back into the rear feeder.
4. **Continue**: the even pages print in the order your printer needs. Blank
   backs are added for odd-length copies so the copies never get mixed up.

Run **Calibration** once per printer (2 sheets). It sets the back-side order and
rotation for that printer.

## Code
- `lib/duplex_plan.dart` — which pages go on the front and back passes
- `lib/ipp/` — IPP client and PWG raster encoder
- `lib/print/` — printer discovery and the print engine
- `lib/ui/` — FlipPrint screens
- `lib/scan/` — WSD scanner client
- `tool/ipp_probe.dart <ip>` — check a printer from the PC without printing
- `tool/scan_probe.dart <ip> [out.jpg]` — check or test the scanner from the PC

## Run
```
flutter run -d <android-device>
flutter build apk --release
```

## License
FlipPrint is licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSE). You may use, copy, change
and share it for personal, educational, research and other **noncommercial**
purposes. **Commercial use is not allowed**, including selling it or using it
in a paid product or service. For commercial use, contact the author for a
separate license.

Because it restricts commercial use, this is a *source-available* license,
not an OSI-approved open-source one.
