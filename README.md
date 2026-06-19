# Moga

A native macOS client for OpenScan 3D scanners, built with SwiftUI.

Moga is a reverse-engineered reimplementation of [OpenScan Composer](https://www.openscancomposer.com) — a Windows-only app — using the publicly documented OpenScan firmware network protocol. The firmware on the OpenScan device is unchanged.

## Features (planned)

- Auto-discovery of OpenScan devices on the local network (UDP broadcast)
- Full device control via the OpenScan TCP protocol (port 2050)
- Scan patterns: Spiral, Fibonacci, Uniform
- Focus stacking: capture multiple images at interpolated focus distances per position
- Focus stack merging using Laplacian sharpness weighting
- Background removal (Apple Vision framework)
- Project export for Reality Capture and Meshroom
- OpenScan Cloud upload

## Requirements

- macOS 13 Ventura or later
- OpenScan device running OpenScan Composer firmware

## Project Status

Under active development. See [Issues](../../issues) for the current roadmap.

## Protocol Reference

- [OpenScan Composer Firmware Protocol](https://www.openscancomposer.com/firmware/)

## License

MIT
