use serde::Serialize;

#[derive(Serialize)]
pub(crate) struct WsConnectionRequestEvent {
    pub(crate) event: String,
    pub(crate) connection_id: String,
    pub(crate) requester_id: String,
    pub(crate) requester_username: Option<String>,
    pub(crate) listing_id: Option<String>,
}

#[derive(Serialize)]
pub(crate) struct WsConnectionEstablishedEvent {
    pub(crate) event: String,
    pub(crate) connection_id: String,
    pub(crate) established_at: String,
}

#[derive(Serialize)]
pub(crate) struct WsConnectionRejectedEvent {
    pub(crate) event: String,
    pub(crate) connection_id: String,
}

#[derive(Serialize)]
pub(crate) struct WsNewMessageEvent {
    pub(crate) event: String,
    pub(crate) message_id: i64,
    pub(crate) conversation_id: String,
    pub(crate) sender: String,
    pub(crate) sender_username: Option<String>,
    pub(crate) content: String,
    pub(crate) timestamp: String,
    pub(crate) image_data: Option<String>,
    pub(crate) audio_data: Option<String>,
    pub(crate) image_url: Option<String>,
    pub(crate) audio_url: Option<String>,
}
