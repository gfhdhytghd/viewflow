use viewflow_core::{Coordinator, CoordinatorError};
use viewflow_protocol::{
    ClipboardAccept, ClipboardComplete, ClipboardCompletionStatus, ClipboardFlavor, ClipboardOffer,
    ClipboardPayload, ClipboardTransferFlavor, ClipboardTransferOffer, DomainControl, Id128,
};

fn clipboard_controls() -> [DomainControl; 4] {
    let offer = ClipboardOffer {
        id: Id128(1),
        owner: Id128(2),
        generation: 1,
        flavors: vec![ClipboardFlavor {
            name: "text/plain".to_owned(),
            size_bytes: 3,
        }],
    };
    let offer_nonce = [7; 16];
    [
        DomainControl::ClipboardTransferOffer(ClipboardTransferOffer {
            offer,
            flavors: vec![ClipboardTransferFlavor {
                name: "text/plain".to_owned(),
                size_bytes: 3,
                sha256: [8; 32],
            }],
            offer_nonce,
            consent_correlation: [9; 16],
            connection_binding: [10; 32],
            payload_sequence: 1,
        }),
        DomainControl::ClipboardAccept(ClipboardAccept {
            offer_id: Id128(1),
            generation: 1,
            offer_nonce,
            mime_type: "text/plain".to_owned(),
            payload_sequence: 1,
        }),
        DomainControl::ClipboardPayload(ClipboardPayload {
            offer_id: Id128(1),
            generation: 1,
            offer_nonce,
            payload_sequence: 1,
            mime_type: "text/plain".to_owned(),
            data: b"ok".to_vec(),
        }),
        DomainControl::ClipboardComplete(ClipboardComplete {
            offer_id: Id128(1),
            generation: 1,
            offer_nonce,
            payload_sequence: 1,
            status: ClipboardCompletionStatus::Completed,
            error_message: None,
        }),
    ]
}

#[test]
fn generic_coordinator_rejects_clipboard_runtime_controls() {
    for (sequence, control) in clipboard_controls().into_iter().enumerate() {
        let mut coordinator = Coordinator::default();
        assert_eq!(
            coordinator.apply_control(control.clone()),
            Err(CoordinatorError::ClipboardRuntimeRequired)
        );
        assert_eq!(
            coordinator.apply_control_sequenced(sequence as u64 + 1, control),
            Err(CoordinatorError::ClipboardRuntimeRequired)
        );
    }
}
