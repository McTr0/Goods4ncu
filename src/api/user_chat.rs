//! User-to-user conversations with short-lived realtime handshakes and mail threads.

mod connection;
mod message;
mod models;
mod reply;
mod telegram;

pub use connection::{
    acknowledge_conversation, archive_conversation, block_user, close_conversation,
    create_conversation, get_conversation, get_thread, list_blocks, list_conversations,
    list_threads, respond_conversation, set_read_preference, unblock_user,
};
pub use message::{
    delete_message_reaction, edit_message, get_conversation_messages, hide_message,
    mark_conversation_read, report_message, send_conversation_message, set_message_reaction,
    typing_indicator,
};
pub use reply::reply_suggestions;
pub use telegram::{
    add_space_member, answer_call, create_call, create_secret_session, create_space, end_call,
    get_space, list_secret_messages, list_space_messages, list_spaces, remove_space_member,
    send_secret_message, send_space_message,
};

pub(crate) use connection::{authenticated_user, moderate_text};
pub(crate) use models::*;
