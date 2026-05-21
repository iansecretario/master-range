#!/usr/bin/env bash
# =============================================================================
# VulnLab — Stark Industries CTF Scenario (Debian Edition)
# =============================================================================
# OS      : Debian 11 (Bullseye) / Debian 12 (Bookworm)
# WARNING : ISOLATED / AIR-GAPPED LAB ENVIRONMENT ONLY
# =============================================================================
 
set -euo pipefail
 
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
BLU='\033[0;34m'; CYN='\033[0;36m'; RST='\033[0m'; BLD='\033[1m'
 
banner() { echo -e "\n${CYN}${BLD}[*] $1${RST}"; }
ok()     { echo -e "${GRN}[+] $1${RST}"; }
warn()   { echo -e "${YEL}[!] $1${RST}"; }
info()   { echo -e "${BLU}[-] $1${RST}"; }
 
[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root.${RST}"; exit 1; }
 
LAB_IP=$(hostname -I | awk '{print $1}')
LOGFILE="/var/log/stark_vulnlab.log"
exec > >(tee -a "$LOGFILE") 2>&1
 
# Detect Debian version
DEBIAN_VER=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
info "Detected Debian $DEBIAN_VER"
 
echo -e "${RED}${BLD}"
cat <<'EOF'
  _____ _______       _____  _  __
 / ____|__   __|/\   |  __ \| |/ /
| (___    | |  /  \  | |__) | ' /
 \___ \   | | / /\ \ |  _  /|  <
 ____) |  | |/ ____ \| | \ \| . \
|_____/   |_/_/    \_\_|  \_\_|\_\
  I N D U S T R I E S
  VulnLab CTF — Debian Edition — TRAINING USE ONLY
EOF
echo -e "${RST}"
 
warn "Intentionally insecure. Never expose to public network."
warn "Proceeding in 5 seconds — CTRL+C to abort..."
sleep 5
 
# =============================================================================
# PHASE 0 — PACKAGES
# =============================================================================
banner "PHASE 0 — Installing packages"
 
apt-get update -qq
 
# Debian-specific: install mariadb, php, docker.io from backports if needed
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    openssh-server curl wget git \
    python3 python3-pip \
    apache2 \
    php php-mysqli php-cli libapache2-mod-php \
    mariadb-server \
    nmap netcat-traditional socat \
    cron sudo vim \
    nfs-kernel-server vsftpd \
    gcc make libcap2-bin net-tools \
    fail2ban ufw \
    docker.io \
    john 2>/dev/null || true
 
# Debian 12: php defaults to 8.2; Debian 11: 7.4
PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2")
info "PHP version: $PHP_VER"
 
ok "Packages installed"
 
# =============================================================================
# PHASE 1 — USERS & SSH
# =============================================================================
banner "PHASE 1 — Users & SSH"
 
cat > /etc/ssh/sshd_config <<'SSHCFG'
Port 22
Protocol 2
LoginGraceTime 120
PermitRootLogin yes
StrictModes no
MaxAuthTries 100
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding yes
AcceptEnv LANG LC_* GLIBC_TUNABLES LD_PRELOAD
Subsystem sftp /usr/lib/openssh/sftp-server
LogLevel QUIET
SSHCFG
 
declare -A USERS=(
    ["jarvis_admin"]="3000suits!"
    ["pepper"]="Rescue#2025"
    ["rhodes"]="guidem{nfs_shadow_cracked_mk3}"
    ["hogan"]="HappyH0gan!"
    ["banner"]="Hulk\$mash99"
    ["svcaccount"]=""
)
 
for USER in "${!USERS[@]}"; do
    PASS="${USERS[$USER]}"
    id "$USER" &>/dev/null || useradd -m -s /bin/bash "$USER"
    if [[ -z "$PASS" ]]; then
        passwd -d "$USER"
    else
        echo "$USER:$PASS" | chpasswd
    fi
    ok "User: $USER"
done
 
usermod -aG sudo jarvis_admin
echo "jarvis_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/jarvis_admin
chmod 440 /etc/sudoers.d/jarvis_admin
 
systemctl enable ssh && systemctl restart ssh
ok "SSH configured"
 
# =============================================================================
# PHASE 2 — FTP
# =============================================================================
banner "PHASE 2 — FTP"
 
cat > /etc/vsftpd.conf <<'FTPCFG'
listen=YES
listen_ipv6=NO
anonymous_enable=YES
anon_upload_enable=YES
anon_mkdir_write_enable=YES
write_enable=YES
local_enable=YES
xferlog_enable=NO
connect_from_port_20=YES
anon_root=/var/ftp/pub
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
FTPCFG
 
mkdir -p /var/ftp/pub
chmod 777 /var/ftp/pub
chown nobody:nogroup /var/ftp/pub
systemctl enable vsftpd && systemctl restart vsftpd
ok "FTP: anonymous write enabled"
 
# =============================================================================
# PHASE 3 — WEB APP (StarkNet Portal)
# =============================================================================
banner "PHASE 3 — StarkNet Portal"
 
mkdir -p /var/www/html/starknet/{uploads,assets,api,admin}
chmod 777 /var/www/html/starknet/uploads
 
cat > /var/www/html/starknet/index.php <<'PHP'
<?php session_start(); ?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>StarkNet — Employee Portal</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',sans-serif;background:#0d0d0d;color:#e0e0e0}
.topbar{background:#1a0a00;padding:14px 30px;display:flex;align-items:center;
        justify-content:space-between;border-bottom:3px solid #b45309}
.logo{font-size:1.5rem;font-weight:800;letter-spacing:2px}
.logo .stark{color:#f59e0b}.logo .net{color:#fff}
.logo small{color:#555;font-size:.55rem;font-weight:400;letter-spacing:0}
nav a{color:#888;text-decoration:none;margin-left:22px;font-size:.85rem;
      text-transform:uppercase;letter-spacing:1px}
nav a:hover{color:#f59e0b}
.hero{background:linear-gradient(135deg,#1a0a00,#0d0d0d);padding:55px 30px;
      text-align:center;border-bottom:1px solid #1f1f1f}
.hero h1{font-size:2.2rem;color:#fff;margin-bottom:6px}
.hero h1 span{color:#f59e0b}
.hero p{color:#666;font-size:.9rem;letter-spacing:1px;text-transform:uppercase}
.arc{display:inline-block;width:10px;height:10px;border-radius:50%;
     background:#60a5fa;box-shadow:0 0 8px #60a5fa;margin-right:6px}
.container{max-width:1100px;margin:36px auto;padding:0 20px}
.card{background:#111;border:1px solid #1f1f1f;border-radius:6px;padding:24px;margin-bottom:20px}
.card h2{color:#f59e0b;font-size:.8rem;text-transform:uppercase;
         letter-spacing:2px;margin-bottom:18px;border-bottom:1px solid #1f1f1f;padding-bottom:8px}
input,select{width:100%;padding:10px 12px;background:#0d0d0d;
             border:1px solid #2a2a2a;border-radius:4px;color:#e0e0e0;
             font-size:.88rem;margin:4px 0 12px}
input:focus{outline:none;border-color:#f59e0b}
button{background:#b45309;color:#fff;border:none;padding:10px 22px;
       border-radius:4px;cursor:pointer;font-size:.88rem;font-weight:600;
       text-transform:uppercase;letter-spacing:1px}
button:hover{background:#f59e0b;color:#000}
.result{background:#080808;border:1px solid #1f1f1f;border-radius:4px;
        padding:14px;margin-top:12px;font-family:'Courier New',monospace;
        font-size:.82rem;white-space:pre-wrap;color:#4ade80;max-height:220px;overflow-y:auto}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:20px}
table{width:100%;border-collapse:collapse;font-size:.84rem}
th{background:#080808;color:#666;padding:9px;text-align:left;
   border-bottom:1px solid #1f1f1f;text-transform:uppercase;font-size:.72rem;letter-spacing:1px}
td{padding:9px;border-bottom:1px solid #111}
.badge{display:inline-block;padding:2px 9px;border-radius:3px;
       font-size:.72rem;font-weight:700;text-transform:uppercase;letter-spacing:1px}
.bg{background:#1c1000;color:#f59e0b;border:1px solid #b45309}
.bb{background:#0c1a2e;color:#60a5fa;border:1px solid #1d4ed8}
.br{background:#1f0000;color:#f87171;border:1px solid #7f1d1d}
.footer{text-align:center;color:#333;font-size:.75rem;
        padding:28px;border-top:1px solid #1a1a1a;margin-top:36px}
.alert{padding:10px 14px;border-radius:4px;margin-bottom:14px;font-size:.84rem}
.ai{background:#0c1a2e;border:1px solid #1d4ed8;color:#93c5fd}
</style>
</head>
<body>
<div class="topbar">
  <div class="logo">
    <span class="stark">STARK</span><span class="net">NET</span>
    <small> &nbsp;v3.1.0 — Internal Use Only</small>
  </div>
  <nav>
    <a href="?page=dash">Dashboard</a>
    <a href="?page=network">Diagnostics</a>
    <a href="?page=files">Files</a>
    <a href="?page=directory">Directory</a>
    <a href="login.php">Login</a>
  </nav>
</div>
<div class="hero">
  <h1><span>Stark</span> Industries</h1>
  <p><span class="arc"></span>Employee Portal — Malibu HQ</p>
</div>
<div class="container">
<?php
$page = $_GET['page'] ?? 'dash';
 
if ($page === 'dash'): ?>
<div class="grid2">
  <div class="card">
    <h2>System Status</h2>
    <table>
      <tr><td>Portal</td><td><span class="badge bb">StarkNet v3.1.0</span></td></tr>
      <tr><td>PHP Runtime</td><td><span class="badge bb">PHP <?= phpversion() ?></span></td></tr>
      <tr><td>OS</td><td><span class="badge bb"><?= php_uname('s').' '.php_uname('r') ?></span></td></tr>
      <tr><td>Hostname</td><td><span class="badge bb"><?= gethostname() ?></span></td></tr>
      <tr><td>Server IP</td><td><span class="badge bb"><?= $_SERVER['SERVER_ADDR'] ?></span></td></tr>
      <tr><td>Database</td><td><span class="badge bg">MariaDB — starkdb</span></td></tr>
      <tr><td>ARC Status</td><td><span class="badge bg">ONLINE — 3 petawatt</span></td></tr>
    </table>
  </div>
  <div class="card">
    <h2>Divisions</h2>
    <table>
      <tr><td><span class="badge bg">R&amp;D</span></td><td>ARC Reactor Research</td></tr>
      <tr><td><span class="badge bg">SEC</span></td><td>Iron Man Program</td></tr>
      <tr><td><span class="badge bb">OPS</span></td><td>Global Logistics</td></tr>
      <tr><td><span class="badge bb">IT</span></td><td>JARVIS Infrastructure</td></tr>
      <tr><td><span class="badge br">TS</span></td><td>Weapons — CLASSIFIED</td></tr>
    </table>
    <br>
    <a href="?page=network" style="color:#f59e0b">→ Network Diagnostics</a><br><br>
    <a href="api/status.php" style="color:#f59e0b">→ API Status (v1)</a><br><br>
    <a href="admin/" style="color:#f59e0b">→ JARVIS Admin Console</a>
  </div>
</div>
 
<?php elseif ($page === 'network'): ?>
<div class="card">
  <h2>Network Diagnostics — JARVIS Module</h2>
  <div class="alert ai">JARVIS connectivity checker. Enter a target host to verify internal routing.</div>
  <form method="GET">
    <input type="hidden" name="page" value="network">
    <label style="font-size:.8rem;color:#666">Target Host / IP Address</label>
    <input type="text" name="host"
           value="<?= htmlspecialchars($_GET['host'] ?? '10.0.10.1') ?>"
           placeholder="e.g. 10.0.10.1 or arc-reactor.stark.local">
    <label style="font-size:.8rem;color:#666">Diagnostic Tool</label>
    <select name="tool">
      <option value="ping"       <?= ($_GET['tool']??'')=='ping'?'selected':'' ?>>Ping</option>
      <option value="traceroute" <?= ($_GET['tool']??'')=='traceroute'?'selected':'' ?>>Traceroute</option>
      <option value="nslookup"   <?= ($_GET['tool']??'')=='nslookup'?'selected':'' ?>>NSLookup</option>
    </select>
    <button type="submit" name="run">Run Diagnostic</button>
  </form>
<?php
if (isset($_GET['run'])) {
    $host = $_GET['host'];
    $tool = $_GET['tool'] ?? 'ping';
    $cmds = [
        'ping'       => "ping -c 3 $host",
        'traceroute' => "traceroute -m 8 $host",
        'nslookup'   => "nslookup $host",
    ];
    $cmd = $cmds[$tool] ?? "ping -c 3 $host";
    echo '<div class="result">'.htmlspecialchars(shell_exec("$cmd 2>&1")).'</div>';
}
?>
</div>
 
<?php elseif ($page === 'files'): ?>
<div class="card">
  <h2>Secure File Transfer — R&amp;D Document Vault</h2>
  <div class="alert ai">Upload classified documents. Accepted formats: PDF, DOCX, XLSX.</div>
  <form method="POST" enctype="multipart/form-data">
    <input type="hidden" name="page" value="files">
    <label style="font-size:.8rem;color:#666">Select Document</label>
    <input type="file" name="doc">
    <label style="font-size:.8rem;color:#666">Classification Level</label>
    <select name="level">
      <option>LEVEL-1 — General</option>
      <option>LEVEL-3 — Restricted</option>
      <option>LEVEL-5 — Top Secret</option>
    </select>
    <button type="submit" name="upload">Upload to Vault</button>
  </form>
<?php
if (isset($_POST['upload']) && isset($_FILES['doc'])) {
    $fname = $_FILES['doc']['name'];
    $dest  = __DIR__ . "/uploads/$fname";
    if (move_uploaded_file($_FILES['doc']['tmp_name'], $dest)) {
        echo "<div class='alert ai'>✓ Document secured: <a href='uploads/$fname' style='color:#f59e0b'>$fname</a></div>";
    }
}
echo '<h2 style="margin-top:20px">Vault Contents</h2>';
echo '<table><tr><th>Document</th><th>Size</th><th>Uploaded</th><th></th></tr>';
foreach (glob(__DIR__.'/uploads/*') as $f) {
    $n = basename($f);
    echo "<tr>
      <td><a href='uploads/$n' style='color:#f59e0b'>$n</a></td>
      <td>".round(filesize($f)/1024,1)." KB</td>
      <td>".date('Y-m-d H:i',filemtime($f))."</td>
      <td><a href='uploads/$n' style='color:#4ade80;font-size:.75rem'>OPEN</a></td>
    </tr>";
}
echo '</table>';
?>
</div>
 
<?php elseif ($page === 'directory'): ?>
<div class="card">
  <h2>Personnel Directory — HR Division</h2>
  <form method="GET">
    <input type="hidden" name="page" value="directory">
    <label style="font-size:.8rem;color:#666">Employee ID</label>
    <input type="text" name="id"
           value="<?= htmlspecialchars($_GET['id'] ?? '1') ?>"
           placeholder="Enter employee ID">
    <button type="submit">Lookup</button>
  </form>
<?php
if (isset($_GET['id'])) {
    $conn = new mysqli('localhost','root','','starkdb');
    $id   = $_GET['id'];
    $sql  = "SELECT id,name,email,role,clearance FROM employees WHERE id=$id";
    $res  = $conn->query($sql);
    if ($res && $res->num_rows > 0) {
        echo '<table style="margin-top:16px">
              <tr><th>ID</th><th>Name</th><th>Email</th><th>Role</th><th>Clearance</th></tr>';
        while ($row = $res->fetch_assoc()) {
            $cl = $row['clearance'];
            $cb = $cl >= 4 ? 'br' : ($cl >= 3 ? 'bg' : 'bb');
            echo "<tr>
              <td>{$row['id']}</td><td>{$row['name']}</td>
              <td>{$row['email']}</td><td>{$row['role']}</td>
              <td><span class='badge $cb'>LEVEL-{$row['clearance']}</span></td>
            </tr>";
        }
        echo '</table>';
    } else {
        echo "<div class='result' style='color:#f87171'>Query: $sql\nError: ".$conn->error."</div>";
    }
}
?>
</div>
<?php endif; ?>
</div>
<div class="footer">
  StarkNet Internal Portal v3.1.0 &nbsp;|&nbsp; Stark Industries &copy; 2025 &nbsp;|&nbsp;
  <?= $_SERVER['SERVER_SOFTWARE'] ?> &nbsp;|&nbsp;
  <a href="api/status.php" style="color:#333">API</a> &nbsp;|&nbsp;
  <a href="admin/" style="color:#333">Admin</a>
</div>
</body></html>
PHP
 
# Login page
cat > /var/www/html/starknet/login.php <<'PHP'
<?php
session_start();
$conn = new mysqli('localhost','root','','starkdb');
$err  = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $u = $_POST['username']; $p = $_POST['password'];
    $sql = "SELECT * FROM users WHERE username='$u' AND password='$p'";
    $res = $conn->query($sql);
    if ($res && $res->num_rows > 0) {
        $row = $res->fetch_assoc();
        $_SESSION['user'] = $row['username'];
        header('Location: index.php'); exit;
    } else {
        $err = "Access denied. <!-- debug: $sql -->";
    }
}
?>
<!DOCTYPE html><html><head><title>StarkNet Login</title>
<style>
body{background:#0d0d0d;color:#e0e0e0;font-family:'Segoe UI',sans-serif;
     display:flex;align-items:center;justify-content:center;min-height:100vh}
.box{background:#111;border:1px solid #1f1f1f;border-radius:6px;padding:40px;width:370px}
h2{color:#f59e0b;margin-bottom:6px;font-size:1.1rem;text-transform:uppercase;letter-spacing:2px}
p{color:#444;font-size:.78rem;margin-bottom:24px}
label{font-size:.78rem;color:#666;text-transform:uppercase;letter-spacing:1px}
input{width:100%;padding:10px;background:#0d0d0d;border:1px solid #2a2a2a;
      border-radius:4px;color:#e0e0e0;margin:4px 0 14px;font-size:.9rem}
button{width:100%;background:#b45309;color:#fff;border:none;padding:11px;
       border-radius:4px;cursor:pointer;font-weight:700;text-transform:uppercase;letter-spacing:1px}
button:hover{background:#f59e0b;color:#000}
.err{color:#f87171;font-size:.8rem;margin-bottom:12px;font-family:monospace}
.hint{color:#333;font-size:.72rem;margin-top:18px;text-align:center}
</style></head><body>
<div class="box">
  <h2>StarkNet Access</h2>
  <p>Stark Industries Internal Portal — Authorized Personnel Only</p>
  <?php if ($err): ?><div class="err"><?= $err ?></div><?php endif; ?>
  <form method="POST">
    <label>Username</label><input type="text" name="username" autocomplete="off">
    <label>Password</label><input type="password" name="password">
    <button>Authenticate</button>
  </form>
  <div class="hint">JARVIS Help Desk: ext. 3000 &nbsp;|&nbsp; helpdesk@stark.local</div>
</div>
</body></html>
PHP
 
# API endpoint
cat > /var/www/html/starknet/api/status.php <<'PHP'
<?php
header('Content-Type: application/json');
echo json_encode([
    'system'    => 'StarkNet API Gateway',
    'version'   => '3.1.0',
    'status'    => 'operational',
    'arc_power' => '3PW nominal',
    'db_host'   => 'localhost',
    'db_user'   => 'root',
    'debug'     => true,
    'si_flag'   => 'guidem{api_unauthenticated_r3con}',
    'api_key'   => 'sk-stark-prod-a1b2c3d4e5f6',
    'endpoints' => ['/api/status','/api/employees','/api/suits','/api/arc'],
    'server'    => $_SERVER['SERVER_SOFTWARE'],
]);
PHP
 
# Admin panel
mkdir -p /var/www/html/starknet/admin
cat > /var/www/html/starknet/admin/index.php <<'PHP'
<?php
header('Content-Type: text/plain');
echo "=== JARVIS ADMIN CONSOLE ===\n";
echo "DB     : root@localhost/starkdb (no password)\n";
echo "Backup : /var/backups/stark/\n";
echo "SSH Key: /var/www/html/starknet/id_rsa_backup\n\n";
echo shell_exec('id');
echo shell_exec('cat /etc/passwd');
PHP
 
# Apache config — Debian-specific module names
cat > /etc/apache2/sites-available/starknet.conf <<'APACHECFG'
<VirtualHost *:80>
    DocumentRoot /var/www/html
    ServerSignature On
    ServerTokens Full
    <Directory /var/www/html>
        Options Indexes FollowSymLinks ExecCGI
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
APACHECFG
 
# Debian uses libapache2-mod-php — enable correct versioned module
a2dismod headers 2>/dev/null || true
# Enable the installed PHP mod (Debian names it php<ver>)
PHP_MOD="php${PHP_VER}"
a2enmod "$PHP_MOD" rewrite 2>/dev/null || a2enmod php rewrite 2>/dev/null || true
a2ensite starknet.conf 2>/dev/null || true
a2dissite 000-default 2>/dev/null || true
echo "ServerTokens Full"  >> /etc/apache2/apache2.conf
echo "ServerSignature On" >> /etc/apache2/apache2.conf
 
# SSH private key exposed in webroot
ssh-keygen -t rsa -b 2048 \
    -f /var/www/html/starknet/id_rsa_backup \
    -N "" -C "hogan@stark-industries.com" 2>/dev/null
chmod 644 /var/www/html/starknet/id_rsa_backup
 
systemctl enable apache2 && systemctl restart apache2
ok "StarkNet portal: http://$LAB_IP/starknet/"
 
# =============================================================================
# PHASE 4 — MariaDB (starkdb)
# =============================================================================
banner "PHASE 4 — MariaDB starkdb"
 
systemctl enable mariadb && systemctl start mariadb
 
# Debian MariaDB: root uses unix_socket auth by default — override for lab
mariadb -u root <<'SQL'
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('');
CREATE DATABASE IF NOT EXISTS starkdb;
USE starkdb;
 
CREATE TABLE IF NOT EXISTS employees (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    name      VARCHAR(100), email VARCHAR(100),
    role      VARCHAR(100), ssn   VARCHAR(100),
    salary    INT,          clearance INT
);
INSERT INTO employees VALUES
  (NULL,'Tony Stark',   'tony@stark-industries.com',   'CEO / Chief Engineer',  'redacted',                              2500000,5),
  (NULL,'Pepper Potts', 'pepper@stark-industries.com', 'COO',                   'guidem{sql1_pepper_p0tts_exposed}',     450000, 4),
  (NULL,'James Rhodes', 'rhodes@stark-industries.com', 'Defense Liaison',       '555-33-4455',                           180000, 5),
  (NULL,'Happy Hogan',  'happy@stark-industries.com',  'Head of Security',      '555-77-8899',                           120000, 3),
  (NULL,'Bruce Banner', 'banner@stark-industries.com', 'Lead Scientist — R&D',  '555-55-1234',                           380000, 4),
  (NULL,'Natasha R.',   'natasha@stark-industries.com','Intelligence Analyst',  '555-99-0011',                           310000, 5);
 
CREATE TABLE IF NOT EXISTS users (
    id       INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50), password VARCHAR(100), apikey VARCHAR(100)
);
INSERT INTO users VALUES
  (NULL,'jarvis_admin','guidem{db_dump_3000_suits_stolen}','sk-stark-prod-a1b2c3d4e5f6'),
  (NULL,'pepper',      'Rescue#2025',                      'sk-stark-dev-pepper-9x8y'),
  (NULL,'banner_lab',  'Hulk$mash99',                      'sk-stark-rd-banner-lab');
 
CREATE TABLE IF NOT EXISTS suits (
    id    INT AUTO_INCREMENT PRIMARY KEY,
    model VARCHAR(50), status VARCHAR(50), location VARCHAR(100)
);
INSERT INTO suits VALUES
  (NULL,'Mark III',   'Decommissioned',       'Malibu Vault A'),
  (NULL,'Mark L',     'Active',               'New York Compound'),
  (NULL,'Mark LXXXV', 'Active — CLASSIFIED',  'Deep Storage B'),
  (NULL,'War Machine','Rhodey Custody',        'Edwards AFB');
 
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
 
# Debian MariaDB config path differs from MySQL
MARIADB_CONF=$(find /etc/mysql -name "50-server.cnf" 2>/dev/null | head -1)
if [[ -n "$MARIADB_CONF" ]]; then
    sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' "$MARIADB_CONF"
else
    echo "[mysqld]"          >> /etc/mysql/mariadb.conf.d/99-vulnlab.cnf
    echo "bind-address=0.0.0.0" >> /etc/mysql/mariadb.conf.d/99-vulnlab.cnf
fi
systemctl restart mariadb
ok "starkdb created — employees, users, suits seeded"
 
# =============================================================================
# PHASE 5 — NFS
# =============================================================================
banner "PHASE 5 — NFS"
 
mkdir -p /srv/stark/share
cp /etc/passwd /srv/stark/share/
cp /etc/shadow /srv/stark/share/ 2>/dev/null || true
chmod -R 777 /srv/stark/share
 
grep -q '/srv/stark/share' /etc/exports 2>/dev/null || \
    echo "/srv/stark/share *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
exportfs -ra
systemctl enable nfs-kernel-server && systemctl restart nfs-kernel-server
ok "NFS: /srv/stark/share — no_root_squash"
 
# =============================================================================
# PHASE 6 — PRIVILEGE ESCALATION VECTORS
# =============================================================================
banner "PHASE 6 — Privilege Escalation Vectors"
 
# Debian: vim binary is vim.nox or vim.basic depending on package
VIM_BIN=$(which vim 2>/dev/null || which vim.nox 2>/dev/null || which vim.tiny 2>/dev/null || echo "")
 
for BIN in /usr/bin/find /usr/bin/python3 /usr/bin/less \
           /usr/bin/nmap /usr/bin/env /usr/bin/awk "$VIM_BIN"; do
    [[ -n "$BIN" && -f "$BIN" ]] && chmod u+s "$BIN" && ok "SUID: $BIN"
done
 
# Custom SUID binary
cat > /tmp/starkhelper.c <<'CCODE'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char *argv[]) {
    setuid(0); setgid(0);
    if (argc < 2) { printf("Usage: starkhelper <cmd>\n"); return 1; }
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "/usr/bin/id && %s", argv[1]);
    return system(cmd);
}
CCODE
gcc -o /usr/local/bin/starkhelper /tmp/starkhelper.c
chown root:root /usr/local/bin/starkhelper
chmod 4755 /usr/local/bin/starkhelper
ok "Custom SUID: /usr/local/bin/starkhelper"
 
# Sudo misconfigs
cat > /etc/sudoers.d/starklab <<'SUDO'
pepper     ALL=(ALL) NOPASSWD: /usr/bin/vim
pepper     ALL=(ALL) NOPASSWD: /usr/bin/python3
hogan      ALL=(ALL) NOPASSWD: /usr/bin/find
banner     ALL=(ALL) NOPASSWD: /usr/bin/awk
svcaccount ALL=(ALL) NOPASSWD: /bin/cp, /bin/cat, /bin/tar
SUDO
chmod 440 /etc/sudoers.d/starklab
ok "Sudo misconfigs applied"
 
# Writable cron scripts
mkdir -p /opt/stark/scripts /opt/stark/maintenance/data
cat > /opt/stark/scripts/maintenance.sh <<'CRON'
#!/bin/bash
find /tmp -mtime +1 -delete 2>/dev/null
find /var/log -name "*.gz" -delete 2>/dev/null
CRON
chmod 777 /opt/stark/scripts/maintenance.sh
 
cat > /opt/stark/maintenance/backup.sh <<'BACKUP'
#!/bin/bash
cd /opt/stark/maintenance/data
tar -czf /tmp/stark_backup_$(date +%s).tar.gz *
BACKUP
chmod 777 /opt/stark/maintenance/backup.sh
chmod 777 /opt/stark/maintenance/data
 
(crontab -l 2>/dev/null; echo "* * * * * /opt/stark/scripts/maintenance.sh") | crontab -
(crontab -l 2>/dev/null; echo "*/2 * * * * /opt/stark/maintenance/backup.sh") | crontab -
ok "Cron: world-writable root scripts active"
 
# Docker socket
systemctl enable docker && systemctl start docker 2>/dev/null || true
for U in pepper hogan banner svcaccount; do
    usermod -aG docker "$U" 2>/dev/null || true
done
chmod 666 /var/run/docker.sock 2>/dev/null || true
docker pull alpine:latest 2>/dev/null &
ok "Docker socket: chmod 666"
 
# Capabilities
setcap cap_setuid+ep $(which python3) 2>/dev/null || true
ok "Capabilities: cap_setuid on python3"
 
# Kernel hardening off
cat >> /etc/sysctl.d/99-starklab.conf <<'SYSCTL'
kernel.unprivileged_userns_clone=1
kernel.kptr_restrict=0
kernel.dmesg_restrict=0
SYSCTL
sysctl -p /etc/sysctl.d/99-starklab.conf 2>/dev/null || true
 
# =============================================================================
# PHASE 7 — SENSITIVE DATA
# =============================================================================
banner "PHASE 7 — Seeding Sensitive Data"
 
mkdir -p /var/backups/stark /opt/stark/scripts /srv/data
 
cat > /var/backups/stark/employees_Q1_2025.csv <<'CSV'
id,name,email,ssn,salary,role,clearance,address
1,Tony Stark,tony@stark-industries.com,redacted,2500000,CEO,LEVEL5,"Malibu Point 10880"
2,Pepper Potts,pepper@stark-industries.com,guidem{sql1_pepper_p0tts_exposed},450000,COO,LEVEL4,"Stark Tower NY"
3,James Rhodes,rhodes@stark-industries.com,555-33-4455,guidem{pii_rh0des_salary_exf1ltrated},Defense Liaison,LEVEL5,"Edwards AFB"
4,Happy Hogan,happy@stark-industries.com,555-77-8899,120000,Head of Security,LEVEL3,"Malibu HQ"
5,Bruce Banner,banner@stark-industries.com,555-55-1234,380000,Lead Scientist,LEVEL4,"New York Compound"
6,Natasha Romanoff,natasha@stark-industries.com,555-99-0011,310000,Intelligence Analyst,LEVEL5,"Classified"
CSV
chmod 640 /var/backups/stark/employees_Q1_2025.csv
 
cat > /opt/stark/scripts/deploy_backup.py <<'PY'
#!/usr/bin/env python3
# Stark Industries — Automated Backup Deployment
# CONFIDENTIAL — IT Operations / JARVIS
 
DB_HOST     = "localhost"
DB_USER     = "jarvis_admin"
DB_PASS     = "3000suits!"
AWS_ACCESS  = "AKIA-STARK-INDUSTRIES-2025"
# guidem{aws_k3y_hardcoded_pepper_pot}
AWS_SECRET  = "wJalrXUtnFEMI/StarkKey/bPxRfiCYSTARKKEY"
S3_BUCKET   = "stark-prod-backups-malibu-2025"
GITHUB_PAT  = "ghp_starkIndustriesLabTokenRed2025ab"
SLACK_TOKEN = "xoxb-stark-ops-jarvis-notifications"
PY
chmod 644 /opt/stark/scripts/deploy_backup.py
 
cat > /var/www/html/starknet/.env <<'ENVEOF'
APP_ENV=production
APP_NAME=StarkNet
DB_HOST=localhost
DB_DATABASE=starkdb
DB_USERNAME=root
DB_PASSWORD=
JWT_SECRET=guidem{env_leak_tony_stark_jwt}
ADMIN_PASSWORD=3000suits!
STRIPE_KEY=sk_live_starkIndustriesLabFake
PEPPER_API=sk-stark-prod-a1b2c3d4e5f6
ENVEOF
chmod 644 /var/www/html/starknet/.env
 
cat > /root/.bash_history <<'HIST'
ssh -i ~/.ssh/id_rsa jarvis_admin@10.0.0.50
mariadb -u root -p3000suits! starkdb
curl -H "Authorization: Bearer sk-stark-prod-a1b2c3d4e5f6" https://api.stark.local/suits
aws s3 cp /var/backups/stark s3://stark-prod-backups-malibu-2025 --recursive
docker run -v /:/mnt alpine chroot /mnt
cat /etc/shadow
HIST
 
cat > /home/pepper/.bash_history <<'HIST'
sudo python3 -c 'import os; os.setuid(0); os.system("/bin/bash")'
mariadb -h localhost -u root starkdb -e "SELECT * FROM users"
cat /var/backups/stark/employees_Q1_2025.csv
HIST
 
chmod 640 /etc/shadow
chown root:shadow /etc/shadow
usermod -aG shadow pepper
ok "Sensitive data seeded"
 
# =============================================================================
# PHASE 8 — FTP STAGING
# =============================================================================
banner "PHASE 8 — FTP Staging"
 
cat > /var/ftp/pub/arc_reactor_specs.txt <<'FTPFILE'
guidem{ftp_anon_wr1te_mk85_specs}
Project Codename: MK85
Classification: TOP SECRET — ARC Reactor Division
Output: 3 petawatts sustained
Notes: Do not transmit over unsecured channels.
Authorised access: Stark, Rhodes, Banner only.
FTPFILE
chmod 644 /var/ftp/pub/arc_reactor_specs.txt
ok "FTP: arc_reactor_specs.txt staged"
 
# =============================================================================
# PHASE 9 — PLANT CTF FLAGS
# =============================================================================
banner "PHASE 9 — Planting CTF Flags"
 
ok "Q1:  guidem{api_unauthenticated_r3con}      → starknet/api/status.php"
 
echo "guidem{cmdinject_jarvis_0wned}" > /var/tmp/.si_flag_q2
chmod 644 /var/tmp/.si_flag_q2
ok "Q2:  guidem{cmdinject_jarvis_0wned}          → /var/tmp/.si_flag_q2"
 
echo "guidem{w3bsh3ll_arc_reactor_pwn}" > /var/www/html/starknet/uploads/.hidden_flag
chmod 644 /var/www/html/starknet/uploads/.hidden_flag
ok "Q3:  guidem{w3bsh3ll_arc_reactor_pwn}        → uploads/.hidden_flag"
 
ok "Q4:  guidem{sql1_pepper_p0tts_exposed}       → starkdb.employees Pepper SSN"
ok "Q5:  guidem{db_dump_3000_suits_stolen}        → starkdb.users jarvis_admin password"
ok "Q6:  guidem{env_leak_tony_stark_jwt}          → /var/www/html/starknet/.env"
 
echo "guidem{ssh_k3y_happy_hogan_r00t}" > /home/hogan/.flag
chmod 600 /home/hogan/.flag
chown hogan:hogan /home/hogan/.flag
ok "Q7:  guidem{ssh_k3y_happy_hogan_r00t}        → /home/hogan/.flag"
 
ok "Q8:  guidem{ftp_anon_wr1te_mk85_specs}       → /var/ftp/pub/arc_reactor_specs.txt"
 
echo "guidem{su1d_starkhelper_r00t_shell}" > /root/.stark_flag
chmod 400 /root/.stark_flag
ok "Q9:  guidem{su1d_starkhelper_r00t_shell}     → /root/.stark_flag"
 
echo "guidem{cr0n_wr1table_mk50_privesc}" > /root/.cron_flag
chmod 400 /root/.cron_flag
ok "Q10: guidem{cr0n_wr1table_mk50_privesc}      → /root/.cron_flag"
 
echo "guidem{d0cker_s0cket_host_escape}" > /root/.docker_flag
chmod 400 /root/.docker_flag
ok "Q11: guidem{d0cker_s0cket_host_escape}       → /root/.docker_flag"
 
ok "Q12: guidem{pii_rh0des_salary_exf1ltrated}   → employees_Q1_2025.csv"
ok "Q13: guidem{aws_k3y_hardcoded_pepper_pot}     → deploy_backup.py comment"
ok "Q14: guidem{nfs_shadow_cracked_mk3}           → /etc/shadow rhodes password"
 
cat > /root/TROPHY.txt <<'TROPHY'
╔══════════════════════════════════════════════════════════════╗
║          STARK INDUSTRIES — SECURITY INCIDENT REPORT         ║
║                                                              ║
║  All systems compromised. ARC Reactor data exfiltrated.      ║
║  Iron Man suit inventory accessed. Personnel PII exposed.    ║
║                                                              ║
║  TROPHY: guidem{st4rk_industries_fully_compr0mised_2025}     ║
╚══════════════════════════════════════════════════════════════╝
TROPHY
chmod 400 /root/TROPHY.txt
ok "Q15: guidem{st4rk_industries_fully_compr0mised_2025} → /root/TROPHY.txt"
 
# =============================================================================
# PHASE 10 — DISABLE DEFENCES
# =============================================================================
banner "PHASE 10 — Disabling Security Controls"
 
systemctl disable auditd fail2ban 2>/dev/null || true
systemctl stop    auditd fail2ban 2>/dev/null || true
ufw disable 2>/dev/null || true
iptables -F; iptables -X
iptables -P INPUT   ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT  ACCEPT
echo "" > /var/log/auth.log
echo "" > /var/log/syslog
 
cat > /usr/local/bin/lab_listener <<'SH'
#!/bin/bash
PORT=${1:-4444}
echo "[*] Listening on $PORT"
nc -lvnp "$PORT"
SH
chmod +x /usr/local/bin/lab_listener
ok "Defences disabled, iptables flushed"
 
# =============================================================================
# DONE
# =============================================================================
banner "Stark Industries VulnLab (Debian) — Ready"
echo ""
echo -e "${BLD}OS        : Debian $DEBIAN_VER${RST}"
echo -e "${BLD}DB Engine : MariaDB (starkdb)${RST}"
echo -e "${BLD}Target    : http://$LAB_IP/starknet/${RST}"
echo -e "${BLD}Log file  : $LOGFILE${RST}"
echo ""
printf "%-5s %-48s %s\n" "Q#" "Flag Location" "Pts"
printf "%s\n" "$(printf '─%.0s' {1..65})"
printf "%-5s %-48s %s\n" "Q1"  "GET /starknet/api/status.php → si_flag"       "50"
printf "%-5s %-48s %s\n" "Q2"  "/var/tmp/.si_flag_q2"                          "100"
printf "%-5s %-48s %s\n" "Q3"  "/var/www/html/starknet/uploads/.hidden_flag"   "100"
printf "%-5s %-48s %s\n" "Q4"  "starkdb.employees → Pepper Potts ssn"         "150"
printf "%-5s %-48s %s\n" "Q5"  "starkdb.users → jarvis_admin password"        "150"
printf "%-5s %-48s %s\n" "Q6"  "/var/www/html/starknet/.env → JWT_SECRET"     "75"
printf "%-5s %-48s %s\n" "Q7"  "/home/hogan/.flag (via SSH key)"              "125"
printf "%-5s %-48s %s\n" "Q8"  "/var/ftp/pub/arc_reactor_specs.txt"           "75"
printf "%-5s %-48s %s\n" "Q9"  "/root/.stark_flag (SUID)"                     "200"
printf "%-5s %-48s %s\n" "Q10" "/root/.cron_flag (cron)"                      "200"
printf "%-5s %-48s %s\n" "Q11" "/root/.docker_flag (Docker)"                  "225"
printf "%-5s %-48s %s\n" "Q12" "/var/backups/stark/employees_Q1_2025.csv"     "150"
printf "%-5s %-48s %s\n" "Q13" "/opt/stark/scripts/deploy_backup.py"          "150"
printf "%-5s %-48s %s\n" "Q14" "NFS shadow → crack rhodes password"           "175"
printf "%-5s %-48s %s\n" "Q15" "/root/TROPHY.txt"                             "300"
printf "%s\n" "$(printf '─%.0s' {1..65})"
echo "Total: 2225 points"
echo ""
echo -e "${RED}${BLD}REMINDER: Isolated lab only. Never expose to internet.${RST}"
 
