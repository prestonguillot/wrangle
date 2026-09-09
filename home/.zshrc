alias ckdev=/Users/preston.guillot/Development/other/de_ck-tool/ck.py

#THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"

# The next line updates PATH for the Google Cloud SDK.
if [ -f '/opt/homebrew/share/google-cloud-sdk/path.zsh.inc' ]; then . '/opt/homebrew/share/google-cloud-sdk/path.zsh.inc'; fi

# The next line enables shell command completion for gcloud.
if [ -f '/opt/homebrew/share/google-cloud-sdk/completion.zsh.inc' ]; then . '/opt/homebrew/share/google-cloud-sdk/completion.zsh.inc'; fi

### MANAGED BY RANCHER DESKTOP START (DO NOT EDIT)
export PATH="/Users/pguillot/.rd/bin:$PATH"
### MANAGED BY RANCHER DESKTOP END (DO NOT EDIT)

# ZIA-CERT-STORE-MANAGED profile.d sourcing
if [ -d /etc/profile.d ]; then
  for _zia_f in /etc/profile.d/*.sh; do [ -f "$_zia_f" ] && . "$_zia_f"; done
  unset _zia_f
fi
# ZIA-CERT-STORE-MANAGED-END
