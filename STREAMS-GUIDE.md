# Kino.m3u Management Guide

This guide explains how to find, validate, and add streaming sources to your `kino.m3u` playlist.

## Tools Available

### 1. Check Stream Status
```bash
# Verify all streams in current playlist
./check-streams.sh
```

### 2. Add New Stream Manually
```bash
./add-stream.sh "Channel Name" "http://stream.url/playlist.m3u8"
```

Example:
```bash
./add-stream.sh "Советское кино" "https://example.com/soviet-cinema.m3u8"
```

### 3. Update from Community Sources
```bash
./update-streams.sh
```

Then choose option 1-4 to preview, test, or merge.

## Finding Russian/Soviet Cinema Streams

### Community IPTV Resources
- **GitHub IPTV Lists**: Search `github.com` for `IPTV` + `russian` + `m3u`
  - These lists are maintained by volunteers
  - Frequently updated but entries become stale quickly

- **Reddit Communities**:
  - r/IPTV (discussions and resources)
  - Russian tech forums (search "IPTV каналы")

- **Telegram Groups**:
  - Russian IPTV communities
  - Fastest source for updates

### Specific Cinema Channels to Look For
Common Russian/Soviet cinema channels:
- Советское кино (Soviet Cinema)
- Классика кино (Cinema Classics)  
- Ностальгия (Nostalgia)
- Кинокомедия (Cinema Comedies)
- Русский роман (Russian Romance)
- Домашний (Homemade films)

## Important Notes

⚠️ **IPTV Stream Lifespan**: Most IPTV streams last 2-8 weeks before:
- Tokens expiring
- Servers moving/blocking
- Bandwidth being cut off

✅ **Test Before Adding**: Always validate streams work (HTTP 200) before committing

🔄 **Regular Maintenance**: Review playlist monthly and remove broken streams

## How Streams Break

1. **Token Expiration**: Many streams require auth tokens (e.g., `?token=xyz`)
2. **Geo-blocking**: Server location restrictions
3. **Rate Limiting**: HTTP 423/429 responses  
4. **Server Migration**: Services move domains frequently
5. **Licensing Changes**: Content rights shift

## Validation Process

Before adding a stream, test it:
```bash
curl -I -L "http://stream.url" | head -5
```

Look for:
- **200 OK** - Stream works perfectly
- **302/301** - Redirect (usually works)
- **403/404** - Access denied or not found
- **Timeout** - Server unreachable

## Tips for Finding Reliable Streams

1. **Prefer Official Services**: Prefer streams from known broadcasters (Neterra, Amagi, etc.)
2. **Check Timestamp**: Newer links are more likely to work
3. **Test All Links**: Before mass-adding, validate 5-10 links from a source
4. **Remove Broken Ones**: Use `./check-streams.sh` monthly
5. **Keep Notes**: Add comments about source reliability

## Current Playlist

Your playlist has **12 verified working streams** from various legal IPTV providers:
- RMTV (288p)
- DSTV (614p)
- Музыка Кино
- Music channels
- Magic TV
- City TV
- The Voice TV
- News and entertainment

To improve Soviet cinema coverage, look for channels on:
- Russian cable TV providers' IPTV services
- Legal streaming aggregators
- Archival services (if available)
