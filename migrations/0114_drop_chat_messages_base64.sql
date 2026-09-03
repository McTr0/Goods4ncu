ALTER TABLE chat_messages
DROP COLUMN IF EXISTS image_data,
DROP COLUMN IF EXISTS audio_data;
