-- Store the primary image URL for marketplace listings.
ALTER TABLE inventory
ADD COLUMN IF NOT EXISTS image_url TEXT;

CREATE INDEX IF NOT EXISTS idx_inventory_image_url
ON inventory(image_url)
WHERE image_url IS NOT NULL;
