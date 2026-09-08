# Third-Party Licenses

FXRouter is licensed under GPLv3 (see `LICENSE`). It incorporates the
following third-party code.

## BlackHole — GPLv3

The virtual audio driver (`driver/FXRouter.c`) is a fork of
[BlackHole](https://github.com/ExistentialAudio/BlackHole) v0.7.1 by
Existential Audio Inc., licensed under the GNU General Public License v3.0.

Copyright (C) 2019–2026 Existential Audio Inc.

Only BlackHole's *code* is reused; its name, logo, and branding are not.

## JUCE 8 — AGPLv3

The host engine uses [JUCE](https://juce.com) 8.0.4, fetched at build time via
CMake FetchContent (`engine/CMakeLists.txt`, where the exact revision is
pinned). Copyright © Raw Material Software Limited.

JUCE 8 modules are dual-licensed under the **AGPLv3** and a commercial JUCE
licence. Unlike JUCE 7 and earlier there is no GPLv3 option; FXRouter uses the
AGPLv3 one.

FXRouter as a whole remains licensed under **GPLv3**. Section 13 of the GPLv3
expressly permits combining a GPLv3 work with AGPLv3-licensed code, and the
resulting combination carries AGPLv3 section 13's network-interaction terms
for the JUCE portion. FXRouter is a local desktop application that offers no
network service, so that clause imposes no further obligation in practice.

## VST3 SDK — GPLv3 (via JUCE)

VST3 hosting (`JUCE_PLUGINHOST_VST3=1`) uses Steinberg's VST3 SDK as bundled
inside JUCE, under its GPLv3 option. Copyright © Steinberg Media Technologies
GmbH.

VST is a trademark of Steinberg Media Technologies GmbH, registered in Europe
and other countries.
