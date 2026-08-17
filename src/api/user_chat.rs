//! User-to-user conversations with short-lived realtime handshakes and mail threads.

mod connection;
mod message;
mod models;
mod reply;
mod shared_object;
mod telegram;

pub use connection::{
    acknowledge_conversation, archive_conversation, block_user, close_conversation,
    create_conversation, delete_contact_permission, get_connection_preferences, get_conversation,
    get_relationship_space, get_thread, list_blocks, list_contact_permissions, list_conversations,
    list_threads, open_conversation_for_intent, respond_conversation, set_connection_preferences,
    set_contact_permission, unblock_user,
};
pub use message::{
    delete_message_acknowledgement, delete_message_reaction, edit_message,
    get_conversation_messages, hide_message, pin_message, report_message,
    send_conversation_message, set_message_acknowledgement, set_message_reaction, unpin_message,
};
pub use reply::reply_suggestions;
pub use shared_object::{
    complete_shared_object, create_shared_object, get_shared_object, get_shared_object_media,
    revoke_shared_object,
};
pub use telegram::{
    add_space_member, answer_call, create_call, create_location_child, create_secret_session,
    create_space, end_call, get_location_presence, get_space, heartbeat_location_presence,
    join_location_space, list_location_spaces, list_secret_messages, list_space_messages,
    list_spaces, recommend_location_space, remove_space_member, send_secret_message,
    send_space_message,
};

pub(crate) use connection::{
    authenticated_session, authenticated_user, ensure_active_campus, ensure_conversation_campus,
    ensure_message_campus, moderate_text,
};
pub(crate) use models::*;
