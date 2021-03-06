library(tidyverse)
library(stringr)
library(httr)
library(lubridate)
library(assertthat)
library(rvest)

# Credit: this script is adapted from Charlie Thompson's
# blog post, fitteR happieR: http://rcharlie.com/2017-02-16-fitteR-happieR/

##### IMPORTANT: Copy and paste your access tokens here.

spotify_client_id <- 'xxxxxxxxxx'
spotify_client_secret <- 'xxxxxxxxxx'
genius_token <- 'xxxxxxxxxx'

##### Spotify info.

print("Querying the Spotify API...")

# Get the artist.
get_artists <- function(artist_name) {
        
        # Search Spotify API for artist name
        res <- GET('https://api.spotify.com/v1/search', query = list(q = artist_name, type = 'artist')) %>%
                content %>% .$artists %>% .$items
        
        # Clean response and combine all returned artists into a dataframe
        artists <- map_df(seq_len(length(res)), function(x) {
                list(
                        artist_name = res[[x]]$name,
                        artist_uri = str_replace(res[[x]]$uri, 'spotify:artist:', ''), # remove meta info from the uri string
                        artist_img = ifelse(length(res[[x]]$images) > 0, res[[x]]$images[[1]]$url, NA)
                )
        })
        return(artists)
}

artist_info <- get_artists('kendrick+lamar')

# Filter out other artist matches.
artist_info <- artist_info %>% 
        filter(artist_name == 'Kendrick Lamar')

# Get the albums.
get_albums <- function(artist_uri) {
        
        albums <- GET(paste0('https://api.spotify.com/v1/artists/', artist_uri,'/albums')) %>% content
        
        map_df(1:length(albums$items), function(x) {
                tmp <- albums$items[[x]]
                
                # Make sure the album_type is not "single".
                if (tmp$album_type == 'album') {
                        data.frame(album_uri = str_replace(tmp$uri, 'spotify:album:', ''),
                                   album_name = str_replace_all(tmp$name, '\'', ''),
                                   album_img = albums$items[[x]]$images[[1]]$url,
                                   stringsAsFactors = F) %>%
                                mutate(album_release_date = GET(paste0('https://api.spotify.com/v1/albums/', str_replace(tmp$uri, 'spotify:album:', ''))) %>%
                                               content %>%
                                               .$release_date, 
                                       album_release_year = ifelse(nchar(album_release_date) == 4,
                                                                   year(as.Date(album_release_date, '%Y')),
                                                                   year(as.Date(album_release_date, '%Y-%m-%d'))
                                       )
                                )
                } else {
                        NULL
                }
        }) %>% filter(!duplicated(tolower(album_name))) %>%  # Sometimes there are multiple versions of the same album.
                arrange(album_release_year)
}

album_info <- get_albums(artist_info$artist_uri)

# Filter out deluxe edition of good kid, m.A.A.d. city and Welcome to Compton
non_studio_albums <- c('good kid, m.A.A.d city (Deluxe)', 'Welcome to Compton')
album_info <- filter(album_info, !album_name %in% non_studio_albums)

## Get the tracks.
get_tracks <- function(artist_info, album_info) {
        access_token <- POST('https://accounts.spotify.com/api/token',
                             accept_json(), authenticate(spotify_client_id, spotify_client_secret),
                             body = list(grant_type='client_credentials'),
                             encode = 'form', httr::config(http_version=2)) %>% content %>% .$access_token
        
        track_info <- map_df(album_info$album_uri, function(x) {
                tracks <- GET(paste0('https://api.spotify.com/v1/albums/', x, '/tracks')) %>% 
                        content %>% 
                        .$items 
                
                uris <- map(1:length(tracks), function(z) {
                        gsub('spotify:track:', '', tracks[z][[1]]$uri)
                }) %>% unlist %>% paste0(collapse=',')
                
                res <- GET(paste0('https://api.spotify.com/v1/audio-features/?ids=', uris),
                           query = list(access_token = access_token)) %>% content %>% .$audio_features
                df <- unlist(res) %>% 
                        matrix(nrow = length(res), byrow = T) %>% 
                        as.data.frame(stringsAsFactors = F)
                names(df) <- names(res[[1]])
                df <- df %>% 
                        mutate(album_uri = x,
                               track_number = row_number()) %>% 
                        rowwise %>% 
                        mutate(track_name = tracks[[track_number]]$name) %>%
                        ungroup %>% 
                        left_join(album_info, by = 'album_uri') %>% 
                        rename(track_uri = id) %>% 
                        select(-c(type, track_href, analysis_url, uri))
                return(df)
        }) %>%
                mutate(artist_img = artist_info$artist_img) %>% 
                mutate_at(c('album_uri', 'track_uri', 'album_release_date', 'track_name', 'album_name', 'artist_img'), funs(as.character)) %>%
                mutate_at(c('danceability', 'energy', 'key', 'loudness', 'mode', 'speechiness', 'acousticness', 'album_release_year',
                            'instrumentalness', 'liveness', 'valence', 'tempo', 'duration_ms', 'time_signature', 'track_number'),
                          funs(as.numeric(gsub('[^0-9.-]+', '', as.character(.)))))
        return(track_info)
}

spotify_df <- get_tracks(artist_info, album_info)

# Get rid of the remixes of "Bitch, Don't Kill My Vibe"
spotify_df <- spotify_df %>%
        filter(track_name != "Bitch, Don’t Kill My Vibe - Remix",
               track_name != "Bitch, Don’t Kill My Vibe - International Remix / Explicit Version")

##### Genius Lyrics

print("Querying the Genius API...")

# Get the artist.
genius_get_artists <- function(artist_name, n_results = 10) {
        baseURL <- 'https://api.genius.com/search?q=' 
        requestURL <- paste0(baseURL, gsub(' ', '%20', artist_name),
                             '&per_page=', n_results,
                             '&access_token=', genius_token)
        
        res <- GET(requestURL) %>% content %>% .$response %>% .$hits
        
        map_df(1:length(res), function(x) {
                tmp <- res[[x]]$result$primary_artist
                list(
                        artist_id = tmp$id,
                        artist_name = tmp$name
                )
        }) %>% unique
}

genius_artists <- genius_get_artists('Kendrick Lamar')

# Get the track urls.
baseURL <- 'https://api.genius.com/artists/' 
requestURL <- paste0(baseURL, genius_artists$artist_id[1], '/songs')

track_lyric_urls <- list()
i <- 1
while (i > 0) {
        tmp <- GET(requestURL, query = list(access_token = genius_token, per_page = 50, page = i)) %>% content %>% .$response
        track_lyric_urls <- c(track_lyric_urls, tmp$songs)
        if (!is.null(tmp$next_page)) {
                i <- tmp$next_page
        } else {
                break
        }
}

# Initialize vectors to hold the Genius info.
filtered_track_lyric_urls <- c()
filtered_track_lyric_titles <- c()
filtered_track_annotations <- c()
filtered_track_pageviews <- c()
filtered_track_contributors <- c()
index <- c()

# Keep only the songs where Kendrick is the primary artist.
for (i in 1:length(track_lyric_urls)) {
        if (track_lyric_urls[[i]]$primary_artist$name == "Kendrick Lamar") {
                filtered_track_lyric_urls <- append(filtered_track_lyric_urls, track_lyric_urls[[i]]$url)
                filtered_track_lyric_titles <- append(filtered_track_lyric_titles, track_lyric_urls[[i]]$title)
                filtered_track_annotations <- append(filtered_track_annotations, track_lyric_urls[[i]]$annotation_count)
                if (!is.null(track_lyric_urls[[i]]$stats$pageviews)) {
                        filtered_track_pageviews <- append(filtered_track_pageviews, track_lyric_urls[[i]]$stats$pageviews)
                } else {
                        filtered_track_pageviews <- append(filtered_track_pageviews, NA)
                }
                if (!is.null(track_lyric_urls[[i]]$stats$contributors)) {
                        filtered_track_contributors <- append(filtered_track_contributors, track_lyric_urls[[i]]$stats$contributors)
                } else {
                        filtered_track_contributors <- append(filtered_track_contributors, NA)
                }
                index <- append(index, i)
        }
}

# Fix the many, many mismatches between Spotify's naming and Genius's naming... :(
filtered_track_lyric_titles[filtered_track_lyric_titles == 'Ignorance is Bliss'] <- "Ignorance Is Bliss"
filtered_track_lyric_titles[filtered_track_lyric_titles == 'Alien Girl (Today With Her)'] <- "Alien Girl (Today W/ Her)"
filtered_track_lyric_titles[filtered_track_lyric_titles == "H.O.C."] <- "H.O.C"
filtered_track_lyric_titles[filtered_track_lyric_titles == "Fuck Your Ethnicity"] <- "F*ck Your Ethnicity"
filtered_track_lyric_titles[filtered_track_lyric_titles == 'No Makeup (Her Vice)'] <- "No Make-Up (Her Vice)"
filtered_track_lyric_titles[filtered_track_lyric_titles == 'Ronald Reagan Era (His Evils)'] <- "Ronald Reagan Era"
filtered_track_lyric_titles[filtered_track_lyric_titles == "Poe Man's Dream (His Vice)"] <- "Poe Mans Dreams (His Vice)"
filtered_track_lyric_titles[filtered_track_lyric_titles == 'Kush & Corinthians (His Pain)'] <- "Kush & Corinthians"
filtered_track_lyric_titles[filtered_track_lyric_titles == "Ab-Soul's Outro"] <- "Ab-Souls Outro"
filtered_track_lyric_titles[filtered_track_lyric_titles == "Sherane a.k.a Master Splinter's Daughter"] <- "Sherane a.k.a Master Splinter’s Daughter"
filtered_track_lyric_titles[filtered_track_lyric_titles == "Bitch, Don't Kill My Vibe"] <- "Bitch, Don’t Kill My Vibe"
filtered_track_lyric_titles[119] <- "good kid"
filtered_track_lyric_titles[198] <- "m.A.A.d city"
filtered_track_lyric_titles[filtered_track_lyric_titles == 'Swimming Pools (Drank)'] <- "Swimming Pools (Drank) - Extended Version"
filtered_track_lyric_titles[filtered_track_lyric_titles == "Sing About Me, I'm Dying of Thirst"] <- "Sing About Me, I'm Dying Of Thirst"
filtered_track_lyric_titles[filtered_track_lyric_titles == 'For Free? (Interlude)'] <- "For Free? - Interlude"
filtered_track_lyric_titles[320] <- "u"
filtered_track_lyric_titles[filtered_track_lyric_titles == 'For Sale? (Interlude)'] <- "For Sale? - Interlude"
filtered_track_lyric_titles[filtered_track_lyric_titles == 'How Much a Dollar Cost'] <- "How Much A Dollar Cost"
filtered_track_lyric_titles[filtered_track_lyric_titles == 'The Blacker the Berry'] <- "The Blacker The Berry"
filtered_track_lyric_titles[153] <- "i"
filtered_track_lyric_titles[322] <- "untitled 01 | 08.19.2014."
filtered_track_lyric_titles[323] <- "untitled 02 | 06.23.2014."
filtered_track_lyric_titles[324] <- "untitled 03 | 05.28.2013."
filtered_track_lyric_titles[325] <- "untitled 04 | 08.14.2014."
filtered_track_lyric_titles[326] <- "untitled 05 | 09.21.2014."
filtered_track_lyric_titles[327] <- "untitled 06 | 06.30.2014."
filtered_track_lyric_titles[328] <- "untitled 07 | 2014 - 2016"
filtered_track_lyric_titles[330] <- "untitled 08 | 09.06.2014."
filtered_track_lyric_titles[filtered_track_lyric_titles == "LOYALTY."] <- "LOYALTY. FEAT. RIHANNA."
filtered_track_lyric_titles[filtered_track_lyric_titles == "LOVE."] <- "LOVE. FEAT. ZACARI."
filtered_track_lyric_titles[filtered_track_lyric_titles == "XXX."] <- "XXX. FEAT. U2."

# Check to make sure all of the album songs are now present in the filtered track lyric titles.
# spotify_df$track_name[!spotify_df$track_name %in% filtered_track_lyric_titles]
assert_that(length(spotify_df$track_name[spotify_df$track_name %in% filtered_track_lyric_titles]) == length(spotify_df$track_name))

# Keep only the urls for the songs in the full-length albums.
track_urls <- filtered_track_lyric_urls[filtered_track_lyric_titles %in% spotify_df$track_name]
track_titles <- filtered_track_lyric_titles[filtered_track_lyric_titles %in% spotify_df$track_name]
track_annotations <- filtered_track_annotations[filtered_track_lyric_titles %in% spotify_df$track_name]
track_pageviews <- filtered_track_pageviews[filtered_track_lyric_titles %in% spotify_df$track_name]
track_contributors <- filtered_track_contributors[filtered_track_lyric_titles %in% spotify_df$track_name]

# Make sure they're the same length.
assert_that(length(track_urls) == length(track_titles))
assert_that(length(track_urls) == length(track_annotations))
assert_that(length(track_urls) == length(track_pageviews))
assert_that(length(track_urls) == length(track_contributors))

# Scrape the lyrics.
lyric_scraper <- function(url) {
        read_html(url) %>%
                html_node('lyrics') %>% 
                html_text
}

genius_df <- map_df(1:length(track_urls), function(x) {
        # Add error handling.
        lyrics <- try(lyric_scraper(track_urls[x]))
        if (class(lyrics) != 'try-error') {
                # Strip out non-lyric text and extra spaces.
                lyrics <- str_replace_all(lyrics, '\\n', ' ')
                lyrics <- str_replace_all(lyrics, '\\[(.*?)\\]', '')
                lyrics <- str_replace_all(lyrics, '([A-Z])', ' \\1')
                lyrics <- str_replace_all(lyrics, ' {2,}', ' ')
                lyrics <- tolower(str_trim(lyrics))
        } else {
                lyrics <- NA
        }
        
        
        tots <- list(
                track_name = track_titles[x],
                lyrics = lyrics,
                annotations = track_annotations[x],
                pageviews = track_pageviews[x],
                contributors = track_contributors[x]
        )
        
        return(tots)
})

##### Join the Spotify info with the Genius info.

new_genius_df <- genius_df %>%
        mutate(track_name_join = tolower(str_replace(track_name, '[[:punct:]]', ''))) %>% 
        filter(!duplicated(track_name_join)) %>% 
        select(-track_name)

track_df <- spotify_df %>%
        mutate(track_name_join = tolower(str_replace(track_name, '[[:punct:]]', ''))) %>%
        left_join(new_genius_df, by = 'track_name_join')

# Add a career-wide track number.
track_df$career_track_number <- 1:dim(track_df)[1]

# Add the character count for each set of lyrics.
track_df$song_char_count <- nchar(track_df$lyrics)

# Add the word count.
word_count <- c()
for (i in 1:length(track_df$lyrics)) {
        word_count <- append(word_count, length(strsplit(track_df$lyrics[i],' ')[[1]]))
}

track_df$song_word_count <- word_count

# Save it all to csv.
write.csv(track_df, "../data/scraped_kendrick_data.csv")

print("Done.")
