Here are the shell commands to execute the cleanup processes directly from the Terminal.

> **Warning:** Using `rm -rf` is powerful and irreversible. Please ensure you copy these commands exactly. It is highly recommended to have a current backup (on an external drive) before proceeding.

### 1. Delete Local Time Machine Snapshots

This is usually the biggest win. It removes local backups that are waiting to be transferred to your external drive.

**Check for snapshots:**

```bash
tmutil listlocalsnapshots /

```

**Delete all snapshots at once:**

```bash
for d in $(tmutil listlocalsnapshotdates | grep "-"); do sudo tmutil deletelocalsnapshots $d; done

```

_You will need to enter your admin password. It will not appear on screen as you type._

---

### 2. Clear User Caches

This targets the `~/Library/Caches` folder. It removes the _contents_ of cache folders without removing the folders themselves (which can sometimes cause app preferences to reset).

**Check the size of your cache folder first:**

```bash
du -sh ~/Library/Caches

```

**Clear specific heavy caches (Recommended):**
Instead of nuking everything, target the usual suspects:

```bash
# Clear Chrome Cache
rm -rf ~/Library/Caches/Google/Chrome/*

# Clear Spotify Cache
rm -rf ~/Library/Caches/com.spotify.client/*

# Clear Slack Cache
rm -rf ~/Library/Caches/com.tinyspeck.slackmacgap/*

```

**Nuclear Option (Delete all user caches):**
_Use this only if specific cleanup didn't help. Apps will rebuild these files slowly upon next launch._

```bash
rm -rf ~/Library/Caches/*

```

---

### 3. Remove Old iOS/iPad Backups

If you sync devices locally, these backups are massive.

**List backups to see sizes:**

```bash
du -sh ~/Library/Application\ Support/MobileSync/Backup/*

```

**Delete all device backups:**

```bash
rm -rf ~/Library/Application\ Support/MobileSync/Backup/*

```

---

### 4. Clear Xcode Derived Data (Developers Only)

If you use Xcode, this folder grows indefinitely with every build.

**Check size:**

```bash
du -sh ~/Library/Developer/Xcode/DerivedData

```

**Delete contents:**

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/*

```

---

### 5. Clear System Logs

Sometimes a specific application goes haywire and writes massive error logs.

**Check for large log files (User & System):**
This command lists all log files larger than 50MB in your user and system log directories.

```bash
find ~/Library/Logs /Library/Logs -size +50M -print

```

**Delete all logs (Safe to do, they regenerate):**

```bash
sudo rm -rf /Library/Logs/*
rm -rf ~/Library/Logs/*

```

### 6. Manage Homebrew (If installed)

If you use Homebrew, it keeps old versions of packages and downloads.

**Cleanup command:**

```bash
brew cleanup --prune=all

```

### Next Step

Would you like a "one-liner" alias command you can add to your `.zshrc` profile to run a safe maintenance sweep (logs + snapshots + brew) with a single word?
