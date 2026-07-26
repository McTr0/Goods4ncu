-- API-layer media quarantine (Phase 1: 未审核媒体不会公开原始对象).
--
-- From this migration on, public read paths only serve `image_url` /
-- `avatar_url` when the resource's moderation status is 'approved'. Submission
-- sets 'pending' in the same transaction as the moderation job (or 'approved'
-- directly when image moderation is disabled by configuration).

-- Upgrade compatibility: rows that are 'pending' but have NO live moderation
-- job were uploaded while moderation was disabled (or before job wiring
-- existed) — nothing will ever review them, so hiding them forever would
-- silently break existing content. Treat them as review-exempt.
UPDATE users u
SET avatar_moderation_status = 'approved'
WHERE u.avatar_moderation_status = 'pending'
  AND NOT EXISTS (
      SELECT 1 FROM moderation_jobs j
      WHERE j.resource_type = 'avatar'
        AND j.resource_id = u.id
        AND j.status IN ('pending', 'processing')
  );

UPDATE inventory i
SET images_moderation_status = 'approved'
WHERE i.images_moderation_status = 'pending'
  AND NOT EXISTS (
      SELECT 1 FROM moderation_jobs j
      WHERE j.resource_type = 'listing_image'
        AND j.resource_id = i.id
        AND j.status IN ('pending', 'processing')
  );

-- Pin the vocabulary so a typo cannot invent an unreviewable state.
ALTER TABLE inventory
    DROP CONSTRAINT IF EXISTS inventory_images_moderation_status_check;
ALTER TABLE inventory
    ADD CONSTRAINT inventory_images_moderation_status_check
    CHECK (images_moderation_status IN ('pending', 'approved', 'rejected', 'failed'));

ALTER TABLE users
    DROP CONSTRAINT IF EXISTS users_avatar_moderation_status_check;
ALTER TABLE users
    ADD CONSTRAINT users_avatar_moderation_status_check
    CHECK (avatar_moderation_status IN ('pending', 'approved', 'rejected', 'failed'));
