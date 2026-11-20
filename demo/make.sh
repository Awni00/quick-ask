#!/bin/zsh
# Renders the README media into docs/: the demo video (MP4 and GIF) and stills.
# Needs ffmpeg. The popup is the real UI in Resources/web; see demo/render.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/demo
mkdir -p $out docs
swiftc -O -swift-version 5 demo/render.swift -o $out/render

rm -rf $out/frames
$out/render demo $out/frames 30
for scene in code empty; do $out/render $scene $out/stills; done

# MP4 (full Retina frames, scaled to 1600 wide) and a smaller GIF for the README.
ffmpeg -loglevel error -y -framerate 30 -i $out/frames/%05d.png \
  -vf "scale=1600:-2:flags=lanczos" -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart \
  docs/demo.mp4
ffmpeg -loglevel error -y -framerate 30 -i $out/frames/%05d.png \
  -vf "fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  docs/demo.gif

# README header, one per GitHub theme (transparent background).
swiftc -O -swift-version 5 demo/snapshot.swift -o $out/snapshot
for theme in light dark; do
  $out/snapshot "file://$PWD/demo/header.html#$theme" docs/header-$theme.png 720 150
done

# Stills at their Retina size, as PNG.
for scene in code empty; do cp $out/stills/$scene.png docs/$scene.png; done
ls -la docs
