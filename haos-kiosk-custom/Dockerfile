FROM ghcr.io/home-assistant/amd64-base:3.19

RUN apk update && apk add --no-cache \
  xorg-server \
  xf86-video-intel \
  xf86-video-fbdev \
  xf86-video-modesetting \
  xf86-video-vesa \
  xf86-input-libinput \
  xinput \
  dbus \
  ttf-freefont \
  openbox \
  xset \
  xsetroot \
  xrandr \
  setxkbmap \
  xkeyboard-config \
  chromium \
  python3 \
  py3-aiohttp \
  bash \
  eudev \
  util-linux \
  procps \
  tini \
  matchbox-keyboard \
  xdotool \
  jq \
  sed \
  grep \
  awk \
  coreutils \
  findutils \
  && rm -rf /tmp/* /var/cache/apk/*

COPY run.sh /
COPY rest_server.py /
RUN chmod a+x /run.sh

CMD ["/run.sh"]

