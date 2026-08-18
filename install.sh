#!/bin/sh
set -e
cd "$(dirname "$0")"

swift build -c release

mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
for bin in janitord janitor AgentJanitorMenu agent-session; do
    cp -f ".build/release/$bin" "$HOME/.local/bin/$bin"
done

launchctl bootout "gui/$(id -u)/com.bootoshi.agentjanitor.daemon" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.bootoshi.agentjanitor.menu" 2>/dev/null || true

sed "s|__HOME__|$HOME|g" launchd/com.bootoshi.agentjanitor.daemon.plist > "$HOME/Library/LaunchAgents/com.bootoshi.agentjanitor.daemon.plist"
sed "s|__HOME__|$HOME|g" launchd/com.bootoshi.agentjanitor.menu.plist > "$HOME/Library/LaunchAgents/com.bootoshi.agentjanitor.menu.plist"

launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.bootoshi.agentjanitor.daemon.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.bootoshi.agentjanitor.menu.plist"

sleep 3
"$HOME/.local/bin/janitor" status
