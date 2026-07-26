# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [0.1.0] - 2026-07-26

### Added
- HTTP client — `http-request` with `http-get`/`http-post`/`http-put`/
  `http-delete`/`http-head`
- HTTP servers — `http-listen`, `http-listen-threaded`,
  `http-listen-prefork`, `http-listen-fiber` (reactor-driven, fiber per
  connection), and `http-listen-parallel` (multi-core)
- Request/response records with accessors
- Built on kaappi-net; native helper library built via `make`
- CI workflow covering offline, server, parallel-server, and fiber-server
  suites
