cat > obfuscate_proxy.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
src="proxy.sh"
dst="proxy_obf.sh"
[[ -f "$src" ]] || { echo "❌ $src not found"; exit 1; }

# Base64-encode the source without line wraps
payload="$(base64 -w0 "$src")"

cat > "$dst" <<'OBF'
#!/usr/bin/env bash
# Obfuscated wrapper generated from proxy.sh
set -euo pipefail
# minimal anti-tamper: refuse if not bash
[ -n "${BASH_VERSION:-}" ] || { echo "Requires bash"; exit 1; }

# Randomized variable names (don’t matter, just noise)
__A__="echo"; __B__="base64"; __C__="mktemp"; __D__="trap"; __E__="bash"; __F__="rm -f"

# Payload blob (base64 of the original script)
__P__="__PAYLOAD__"

# Decode to a temp file, execute, then clean up
__TMP__="$($__C__)"
$__D__ "$__F__ \"$__TMP__\"" EXIT
printf '%s' "$__P__" | $__B__ -d > "$__TMP__"
chmod +x "$__TMP__"
exec "$__E__" "$__TMP__" "$@"
OBF

# inject payload
sed -i "s|__PAYLOAD__|${payload}|g" "$dst"
chmod +x "$dst"
echo "✅ Created $dst (obfuscated). Original left untouched."
EOF
chmod +x obfuscate_proxy.sh && ./obfuscate_proxy.sh
