# Gesture rollback on finger lift: version 12

The user reported that version 11 responds to gestures but springs back when
fingers lift. Read-only status after that trial showed 3,804 submitted reports,
peak four contacts, four button transitions, zero input errors, and zero
unknown initialization requests. This confirms input reached the native path;
it does not establish correct gesture completion.

Code inspection found that ordinary physical all-up frames went through
State::apply, which emitted only the stop report. The Linux sender immediately
followed it with an empty snapshot at the same timestamp. The inactive-contact
phase existed only in disconnect cleanup. This is a concrete lifecycle defect
consistent with the reported rollback; the user's physical retest is needed
to determine whether it fully explains the symptom.

Version 12 makes ordinary all-up and disconnect use one completion path:

1. End the existing contact IDs at their final coordinates.
2. Mark those contacts inactive, with zero classification/pressure/area.
3. Send the empty report that closes the gesture.

The native 21-bit millisecond timestamps advance for lifecycle reports sharing
one physical event, handle wrap, and never go backward for the next immediate
gesture. The sender's redundant empty snapshot is absorbed after completion.
Partial finger lifts retain the remaining gesture. Failed tails retain their
state and complete before a subsequent gesture is sent.

The [reference native encoder](https://github.com/acidanthera/VoodooInput/blob/master/VoodooInput/VoodooInputSimulator/VoodooInputSimulatorDevice.cpp)
also has explicit inactive and empty end phases; the
[protocol fields](https://github.com/acidanthera/VoodooInput/blob/master/VoodooInput/VoodooInputSimulator/VoodooInputSimulatorDevice.hpp)
identify stop state 7 and inactive state 0. Viewflow's implementation remains
its own byte encoder and state machine.

Offline regressions cover natural four-finger lift, ID/coordinate preservation,
partial lift, duplicate empty suppression, same-timestamp next gesture,
failed-tail retry before a new gesture, and native timestamp wrap. C++ tests
pass with address/undefined behavior sanitizers, all eight Python tests pass,
and the Mac DriverKit build passes. No live input was injected during these
checks.

Signed installation completed and the normal restart at 17:06:39 EDT loaded
version 12, PID 295, from SystemExtensions/4087A9C6-83A1-48EC-AC94-3BC69BBB9CDC.
The running executable SHA256 matches the signed embedded artifact:
`87e5641fedb87611c08b2b48f24b77f9b8c56b6b93fb206b81a91dc47a8cfe9a`.
Read-only status has native attachment true, ABI 2/profile 1, five feature gets,
four sets, zero unknown features and zero input errors/submissions. The
[runtime tree](native-v12-runtime-tree.json) retains parser 1000/options 39,
correct surface dimensions, zero Critical Errors and a WindowServer native
user client. User-operated gesture retest remains pending.
