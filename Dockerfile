# Cairn server image = PocketBase + the built Flutter web app + schema migrations.
#
# CI builds the web bundle first (`flutter build web`), THEN `docker build` here
# copies it in — so the Flutter SDK is not needed inside this image.
FROM alpine:3.20

ARG PB_VERSION=0.40.1
RUN apk add --no-cache unzip ca-certificates \
 && wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip" -O /tmp/pb.zip \
 && unzip /tmp/pb.zip -d /pb/ \
 && rm /tmp/pb.zip

# The web app is served at "/" from pb_public.
COPY build/web/ /pb/pb_public/
# Schema migrations run automatically on startup (idempotent).
COPY pb_migrations/ /pb/pb_migrations/

EXPOSE 8090
# pb_data (the real database) is a mounted volume — see deploy/docker-compose.yml.
CMD ["/pb/pocketbase", "serve", "--http=0.0.0.0:8090"]
