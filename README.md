# LiveContainerTV (proof of concept)
Minimal tvOS port of the LiveContainer idea (https://github.com/LiveContainer/LiveContainer): the host app loads a guest tvOS app's main executable (patched MH_EXECUTE→MH_DYLIB) with dlopen and jumps to its LC_MAIN entry, so only the host needs signing.
PoC limits: guest is embedded at build time as `Frameworks/GuestDemo.framework` so the sideloading tool (atvloadly/plumesign) signs it with the same team cert. No in-app signing, no IPA import, no container isolation yet.
