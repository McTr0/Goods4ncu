-- Verify the Qianhu campus anchor from the public Nominatim result supplied
-- during location research. The result points at the mapped university way;
-- keep the room radius coarse and never store an individual observation.
-- Source: https://nominatim.openstreetmap.org/search?format=jsonv2&q=%E5%8D%97%E6%98%8C%E5%A4%A7%E5%AD%A6%E5%89%8D%E6%B9%96%E6%A0%A1%E5%8C%BA

UPDATE chat_spaces
   SET latitude = 28.6572190,
       longitude = 115.7931408,
       radius_meters = 1800,
       updated_at = NOW()
 WHERE id = 'c1000000-0000-4000-8000-000000000001'
   AND origin = 'campus_location'
   AND location_slug = 'qianhu-campus';
