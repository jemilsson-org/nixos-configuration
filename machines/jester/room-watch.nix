{ config, lib, pkgs, ... }:

# Motion-triggered room recording ("room-watch"), for watching a hotel room.
# The IPU6/OV2740 camera is only reachable via libcamera/PipeWire, so motion(1)
# cannot read it directly: a GStreamer feed copies the PipeWire camera stream
# into a v4l2loopback node, and motion watches that node.
#
# Off at boot. Start when leaving the room:
#   systemctl --user start room-watch
# Stop on return:
#   systemctl --user stop room-watch
# Recordings land in ~/Videos/room-watch/ (mkv clips + trigger snapshots) and
# rsync to devbox:room-watch/ every 60s so footage survives laptop theft.
# Upload needs the fafnir ssh agent unlocked; test before leaving:
#   systemctl --user status room-watch-sync

let
  gst = pkgs.gst_all_1;
  loopbackDev = "/dev/video42";

  # Embedding dedup: venice has no image-embedding API, so the dedup gate
  # must run fully offline. A perceptual hash (dhash) compares pixel
  # structure, which cannot tell "person got out of bed" from "AC vent
  # flickered the shadows" - both move a similar number of pixels. A CLIP
  # image embedding compares scene semantics instead, so it tolerates
  # lighting noise and small pose shifts while catching real content
  # change. Model: Qdrant's ONNX export of CLIP ViT-B/32 (vision tower
  # only - only image embeddings are needed, not text-image matching),
  # fp32, ~350MB; no quantized build is published for this export. Runs on
  # CPU via onnxruntime: no torch, no pip, no network calls at runtime.
  # Measured ~0.56s/image (0.22-1.28s range) on real snapshots from this
  # camera - fine under the 15s cooldown below.
  dedupPython = pkgs.python3.withPackages (p: [ p.onnxruntime p.pillow p.numpy ]);
  clipModel = pkgs.fetchurl {
    url = "https://huggingface.co/Qdrant/clip-ViT-B-32-vision/resolve/main/model.onnx";
    sha256 = "c68d3d9a200ddd2a8c8a5510b576d4c94d1ae383bf8b36dd8c084f94e1fb4d63";
  };
  # Shared CLIP preprocessing + embedding, sourced by both scripts below:
  # resize shortest side to 224, center-crop, normalize with the standard
  # CLIP mean/std, L2-normalize the output so cosine similarity reduces to
  # a plain dot product.
  clipEmbed = pkgs.writeText "clip-embed.py" ''
    import numpy as np
    from PIL import Image
    import onnxruntime as ort

    MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
    STD = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)

    def embed(model_path, img_path):
        img = Image.open(img_path).convert("RGB")
        w, h = img.size
        scale = 224 / min(w, h)
        nw, nh = round(w * scale), round(h * scale)
        img = img.resize((nw, nh), Image.BICUBIC)
        left, top = (nw - 224) // 2, (nh - 224) // 2
        img = img.crop((left, top, left + 224, top + 224))
        arr = np.asarray(img, dtype=np.float32) / 255.0
        arr = (arr - MEAN) / STD
        arr = arr.transpose(2, 0, 1)[None, ...].astype(np.float32)
        sess = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
        out = sess.run(None, {sess.get_inputs()[0].name: arr})[0]
        v = out.reshape(-1).astype(np.float32)
        return v / np.linalg.norm(v)
  '';
  # Prints the cosine similarity (-1..1) between the snapshot's embedding
  # and the last-sent snapshot's stored embedding. Prints -1 (the minimum
  # possible similarity, forces "send") when there is no previous state or
  # on any error, so a failure sends rather than silently drops - the same
  # fail-open contract the dhash gate had.
  snapshotDistance = pkgs.writeText "snapshot-distance.py" ''
    import sys
    import numpy as np

    exec(open("${clipEmbed}").read())

    model_path, img_path, state_path = sys.argv[1], sys.argv[2], sys.argv[3]
    try:
        e = embed(model_path, img_path)
        prev = np.loadtxt(state_path, dtype=np.float32)
        print(float(np.dot(e, prev)))
    except Exception:
        print(-1.0)
  '';
  saveEmbedding = pkgs.writeText "snapshot-save-embedding.py" ''
    import os
    import sys
    import numpy as np

    exec(open("${clipEmbed}").read())

    model_path, img_path, state_path = sys.argv[1], sys.argv[2], sys.argv[3]
    e = embed(model_path, img_path)
    # Atomic write: a crash mid-write must not leave a corrupt state file.
    tmp = state_path + ".tmp"
    np.savetxt(tmp, e)
    os.replace(tmp, state_path)
  '';

  # Telegram alert with an AI one-liner. Vision via the local
  # venice-subscription-api (port 8000); falls back to a bare caption if the
  # description fails so the photo still arrives. Credentials (not in repo):
  # ~/.config/room-watch/telegram.env with TELEGRAM_BOT_TOKEN and
  # TELEGRAM_CHAT_ID. Missing env file = hook exits quietly (feature off).
  notifyScript = pkgs.writeShellScript "room-watch-notify" ''
    img="$1"
    [ -f /home/jonas/.config/room-watch/telegram.env ] || exit 0
    . /home/jonas/.config/room-watch/telegram.env
    [ -n "$TELEGRAM_BOT_TOKEN" ] || exit 0

    # Skip near-duplicate snapshots: only alert when the scene differs enough
    # semantically from the last snapshot we sent. Cosine similarity of CLIP
    # ViT-B/32 embeddings, threshold 0.80 (skip when similarity >= 0.80,
    # send when lower). Calibrated on 56 real snapshots from this camera:
    # eyeballing the actual pairs, same-moment/pose frames (a person
    # shifting slightly in bed, 21s apart) scored 0.85-0.99, while pairs
    # with real scene change (person got out of bed and walked off, 28s
    # apart; wide shot vs. close-up face, 43s apart) scored 0.52-0.78. 0.80
    # sits in the clean gap between the highest confirmed-distinct pair
    # (0.77) and the lowest confirmed-same pair (0.85). Tune down if real
    # changes are missed, up if AC/heater flicker still gets through.
    # Recording is unaffected; this only gates the Telegram send.
    statefile=/home/jonas/Videos/room-watch/.last-sent-embedding

    # Cooldown: with picture_output on, motion fires this hook per frame; a
    # person moving continuously can beat the similarity threshold
    # repeatedly, so cap sends to one per 15s regardless of similarity.
    # Activities the user cares to distinguish span minutes; 15s loses
    # nothing.
    now=$(${pkgs.coreutils}/bin/date +%s)
    last=$(${pkgs.coreutils}/bin/stat -c %Y "$statefile" 2>/dev/null || ${pkgs.coreutils}/bin/echo 0)
    [ $((now - last)) -ge 15 ] || exit 0

    sim=$(${dedupPython}/bin/python3 ${snapshotDistance} ${clipModel} "$img" "$statefile")
    if ${pkgs.gawk}/bin/awk -v s="$sim" 'BEGIN { exit !(s >= 0.80) }'; then
      ${pkgs.coreutils}/bin/echo "skipping near-duplicate snapshot (similarity $sim): $img"
      exit 0
    fi

    # venice.ai intermittently drops the attachment (same request, ~1 in 4
    # replies "NO IMAGE" in testing); one retry covers it.
    for attempt in 1 2; do
    desc=$(${pkgs.coreutils}/bin/timeout 60 ${pkgs.bash}/bin/bash -c '
      b64=$(${pkgs.coreutils}/bin/base64 -w0 "'"$img"'")
      ${pkgs.curl}/bin/curl -s -m 55 localhost:8000/v1/chat/completions \
        -H "Content-Type: application/json" \
        --data-binary @<(printf %s "{\"model\":\"qwen3-vl-235b-a22b\",\"max_tokens\":100,
          \"messages\":[{\"role\":\"user\",\"content\":[
            {\"type\":\"text\",\"text\":\"One factual sentence: what is happening in this hotel-room security snapshot? Note any person or change.\"},
            {\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,$b64\"}}]}]}") \
      | ${pkgs.jq}/bin/jq -r ".choices[0].message.content // empty"
    ') || desc=""
      case "$desc" in
        ""|*"NO IMAGE"*|*"cannot see"*|*"can't see"*) continue ;;
        *) break ;;
      esac
    done
    case "$desc" in
      *"NO IMAGE"*|*"cannot see"*|*"can't see"*) desc="" ;;
    esac
    [ -n "$desc" ] || desc="Motion detected"

    ${pkgs.curl}/bin/curl -s -m 30 \
      "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendPhoto" \
      -F "chat_id=$TELEGRAM_CHAT_ID" -F "photo=@$img" \
      -F "caption=$desc" >/dev/null \
      && ${dedupPython}/bin/python3 ${saveEmbedding} ${clipModel} "$img" "$statefile" \
      || ${pkgs.coreutils}/bin/echo "telegram send failed for $img" >&2
  '';

  motionConf = pkgs.writeText "room-watch-motion.conf" ''
    video_device ${loopbackDev}
    width 1280
    height 720
    framerate 15

    target_dir /home/jonas/Videos/room-watch

    # Sensitivity: pixels changed to count as motion; tune up if the
    # aircon curtain-flutter false-triggers.
    threshold 1500
    lightswitch_percent 10
    despeckle_filter EedDl
    minimum_motion_frames 2
    event_gap 10
    pre_capture 15
    post_capture 30

    on_picture_save ${notifyScript} %f
    movie_output on
    movie_codec mkv
    movie_quality 60
    # Save snapshots throughout the event, not just the first frame: the
    # notify hook's embedding-similarity gate + cooldown picks out distinct
    # activities (making the bed vs. at the desk) and drops near-duplicates.
    picture_output on
    text_left ROOM %Y-%m-%d %T

    webcontrol_port 0
    stream_port 0
    log_level 5
  '';
in
{
  # v4l2loopback kernel-module config (video_nr=42, card_label=room-watch)
  # lives in ./v4l2loopback.nix, shared with presence-lock.nix: the module is
  # a single instance and its options can't be split across two stanzas.

  systemd.user.services.room-watch-feed = {
    description = "PipeWire camera feed into v4l2loopback for room-watch";
    requires = [ "pipewire.service" ];
    after = [ "pipewire.service" "wireplumber.service" ];
    # PartOf: `systemctl --user stop room-watch` must take the camera feed
    # down too (Requires= only propagates stop in the other direction).
    partOf = [ "room-watch.service" ];
    serviceConfig = {
      # target-object: the libcamera node name for the built-in camera.
      # 1280x720 matches the 16:9 sensor (1932x1092): 4:3 modes crop the
      # sides and look zoomed in. Converted to YUY2 for motion's sake.
      ExecStart = ''
        ${gst.gstreamer}/bin/gst-launch-1.0 -e \
          pipewiresrc target-object=libcamera_input.__SB_.PC00.LNK1 \
          ! videoconvert ! video/x-raw,format=YUY2,width=1280,height=720 \
          ! v4l2sink device=${loopbackDev} sync=false
      '';
      Restart = "on-failure";
      RestartSec = 3;
    };
    # .out explicitly: the default gstreamer output is "bin", which lacks the
    # core plugins (capsfilter etc.); without them caps-filter syntax fails.
    environment.GST_PLUGIN_SYSTEM_PATH_1_0 = lib.makeSearchPath "lib/gstreamer-1.0" [
      gst.gstreamer.out gst.gst-plugins-base gst.gst-plugins-good pkgs.pipewire
    ];
  };

  # Offsite copy: push clips to Tigris (fly.io S3) so theft of the laptop
  # doesn't take the evidence with it. Loop instead of per-event motion hooks:
  # a periodic sync catches up automatically after wifi drops.
  # Credentials (not in repo): ~/.config/room-watch/tigris.env with
  #   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY from `fly storage create`.
  systemd.user.services.room-watch-sync = {
    description = "Upload room-watch recordings to Tigris";
    partOf = [ "room-watch.service" ];
    serviceConfig = {
      EnvironmentFile = "/home/jonas/.config/room-watch/tigris.env";
      ExecStart = pkgs.writeShellScript "room-watch-sync" ''
        while true; do
          ${pkgs.rclone}/bin/rclone copy /home/jonas/Videos/room-watch \
            ":s3,provider=Other,env_auth,endpoint='https://fly.storage.tigris.dev':room-watch" \
            || echo "sync failed, retrying in 60s"
          sleep 60
        done
      '';
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  systemd.user.services.room-watch = {
    description = "Motion-triggered room recording";
    requires = [ "room-watch-feed.service" "room-watch-sync.service" ];
    after = [ "room-watch-feed.service" ];
    serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/Videos/room-watch";
      ExecStart = "${pkgs.motion}/bin/motion -n -c ${motionConf}";
      Restart = "on-failure";
      RestartSec = 3;
    };
  };
}
