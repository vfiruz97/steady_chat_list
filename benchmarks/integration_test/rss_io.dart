import 'dart:io';

/// Resident memory of the process in bytes.
int? currentRss() => ProcessInfo.currentRss;
