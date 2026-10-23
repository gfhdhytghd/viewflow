#![no_main]
//! For each control message with a domain encoder: protobuf bytes -> domain
//! value -> protobuf -> domain value must be stable. The first byte picks the
//! message type.
use libfuzzer_sys::fuzz_target;
use prost::Message;
use viewflow_protocol::{
    ApplicationIcon, AtlasDesktopLayout, AtlasFrame, AtlasWindowSelection,
    AtlasWindowSelectionAccepted, AtlasWindowSelectionRejected, ClipboardAccept, ClipboardComplete,
    ClipboardOffer, ClipboardPayload, ClipboardTransferOffer, DesktopRect, DesktopWindowMove,
    DesktopWindowMoveAck, WindowKeyboardAck, WindowKeyboardAuthorization, WindowKeyboardEvent,
    WindowPointerAck, WindowPointerAuthorization, WindowPointerButton, WindowPointerMotion,
    WindowPointerWheel, wire,
};

fn roundtrip<W, D>(bytes: &[u8])
where
    W: Message + Default,
    D: TryFrom<W> + Into<W> + Clone + PartialEq + std::fmt::Debug,
    <D as TryFrom<W>>::Error: std::fmt::Debug,
{
    let Ok(message) = W::decode(bytes) else {
        return;
    };
    let Ok(value) = D::try_from(message) else {
        return;
    };
    let encoded = value.clone().into().encode_to_vec();
    let again = D::try_from(W::decode(encoded.as_slice()).expect("re-encoded protobuf decodes"))
        .expect("re-encoded domain value validates");
    assert_eq!(again, value);
}

fuzz_target!(|data: &[u8]| {
    let Some((&selector, bytes)) = data.split_first() else {
        return;
    };
    match selector % 22 {
        0 => roundtrip::<wire::DesktopRect, DesktopRect>(bytes),
        1 => roundtrip::<wire::AtlasDesktopLayout, AtlasDesktopLayout>(bytes),
        2 => roundtrip::<wire::DesktopWindowMove, DesktopWindowMove>(bytes),
        3 => roundtrip::<wire::DesktopWindowMoveAck, DesktopWindowMoveAck>(bytes),
        4 => roundtrip::<wire::AtlasWindowSelection, AtlasWindowSelection>(bytes),
        5 => roundtrip::<wire::AtlasWindowSelectionRejected, AtlasWindowSelectionRejected>(bytes),
        6 => roundtrip::<wire::AtlasWindowSelectionAccepted, AtlasWindowSelectionAccepted>(bytes),
        7 => roundtrip::<wire::WindowPointerWheel, WindowPointerWheel>(bytes),
        8 => roundtrip::<wire::WindowPointerButton, WindowPointerButton>(bytes),
        9 => roundtrip::<wire::WindowPointerAuthorization, WindowPointerAuthorization>(bytes),
        10 => roundtrip::<wire::WindowPointerAck, WindowPointerAck>(bytes),
        11 => roundtrip::<wire::WindowPointerMotion, WindowPointerMotion>(bytes),
        12 => roundtrip::<wire::ApplicationIcon, ApplicationIcon>(bytes),
        13 => roundtrip::<wire::ClipboardOffer, ClipboardOffer>(bytes),
        14 => roundtrip::<wire::ClipboardTransferOffer, ClipboardTransferOffer>(bytes),
        15 => roundtrip::<wire::ClipboardAccept, ClipboardAccept>(bytes),
        16 => roundtrip::<wire::ClipboardPayload, ClipboardPayload>(bytes),
        17 => roundtrip::<wire::ClipboardComplete, ClipboardComplete>(bytes),
        18 => roundtrip::<wire::WindowKeyboardAuthorization, WindowKeyboardAuthorization>(bytes),
        19 => roundtrip::<wire::WindowKeyboardAck, WindowKeyboardAck>(bytes),
        20 => roundtrip::<wire::WindowKeyboardEvent, WindowKeyboardEvent>(bytes),
        _ => roundtrip::<wire::AtlasFrame, AtlasFrame>(bytes),
    }
});
