CREATE TABLE IF NOT EXISTS vehicle_description (
    vehicle_id INT PRIMARY KEY,
    vehicle_brand TEXT NOT NULL,
    driver_name TEXT NOT NULL,
    license_plate TEXT NOT NULL
);

-- Arrays for deterministic data assignment
DO $$
DECLARE
    brands TEXT[] := ARRAY['Renault','Mercedes-Benz','Volvo','MAN','Scania'];
    drivers TEXT[] := ARRAY[
        'Frieda Baldi','Cherrita Gallaccio','Matt Cleugh','Dulciana Murfill','Germayne Streetley','Brenna Woolfall','Gerhardt Tenbrug','Hayley Tuma','Winny Cadigan','Bonnibelle Macek',
        'Lionel Byneth','Trev Roper','Lena MacFadzean','Benton Allcorn','Avis Moyler','Marchall Rochewell','Adele Bohl','Barnett Mcall','Frieda Pirrone','Pattin Eringey',
        'Kalila Fewings','Giacobo Beuscher','Rozalin Hair','Egon Beagan','Owen Strotton','Fernando Rosensaft','Carleton Gwyther','Kata Coll','Rossie Hobben','Stephanie Gookey',
        'Robyn Milazzo','Tilda OLunney','Nolan Kidney','Jori Ottiwill','Benito Graveson','Zechariah Wrate','Chelsae Napton','Jeremy Heffernon','Derk McAviy','Constantin Mears',
        'Fitz Ballin','Essy Bettles','Gene Klemt','Nikolai Arnopp','Gustave Westhofer','Simona Mayhow','Cort Bainbridge','Sibyl Vockins','Andriette Gaze','Shaughn De Simoni',
        'Nathaniel Hallowell','Charley Dudill','Cirstoforo Joblin','Hyacinthia Kinastan','Dur Lasselle','Gay Chadburn','Livvie Hawyes','Aldrich MacVay','Riva Rossant','Johanna Reichartz',
        'Trent Gantlett','Aryn Haskell','Byrann Barock','Gerda Cleugher','Sonnie Guildford','Vergil Borge','Lurline Rocco','Geoff Eddy','Zea Leighton','Leif Baden',
        'Quint Bidgod','Talbot Cashell','Sheridan Foulsham','Camile Shrimplin','Marcel Nayshe','Lea Murrish','Lucais Midson','Zeb Rylatt','Nertie Zuker','Babara Henderson',
        'Electra Ridgley','Jere Standingford','Cyril Yellowlea','Isadora Peegrem','Caria Smewings','Karena Kauffman','Haywood Snowball','Winslow Starcks','Alis Ponton','Marietta Lezemere',
        'Emilee Broadbridge','Faye Beaument','Shannah Beatson','West Doy','Chryste Wren','Trumann Labba','Anatollo Beckwith','Konstanze Dunsford','Raychel Roset','Heindrick Ravenscroft'
    ];
    i INT;
    lic TEXT;
    letter1 TEXT;
    letter2 TEXT;
    letter3 TEXT;
BEGIN
    FOR i IN 0..149 LOOP
        -- Generate deterministic letters based on id
        letter1 := chr(65 + (i % 26));
        letter2 := chr(65 + ((i / 26) % 26));
        letter3 := chr(65 + ((i / 10) % 26));
        lic := letter1 || letter2 || lpad((i::text), 6, '0') || letter3; -- Pattern: [A-Z]{2}\d{6}[A-Z]
        INSERT INTO vehicle_description(vehicle_id, vehicle_brand, driver_name, license_plate)
        VALUES (
            i,
            brands[(i % array_length(brands,1)) + 1],
            drivers[((i % array_length(drivers,1)) + 1)],
            lic
        ) ON CONFLICT (vehicle_id) DO NOTHING;
    END LOOP;
END$$;
