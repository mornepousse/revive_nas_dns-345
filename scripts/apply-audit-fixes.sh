#!/bin/sh
# Applique sur le NAS les correctifs issus de l'audit de stabilité.
#
#   sh scripts/apply-audit-fixes.sh [user@host]      (défaut: root@192.168.1.27)
#
# Idempotent : relançable sans dommage. Chaque étape annonce ce qu'elle fait et
# la façon de la défaire. Les fichiers remplacés sont sauvegardés dans
# /root/backup-preaudit/ sur le NAS.
#
# À lancer depuis la racine du dépôt, après un ./scripts/check.sh vert.

set -eu
NAS="${1:-root@192.168.1.27}"
SSH="ssh -o BatchMode=yes $NAS"

step() { echo; echo "=== $* ==="; }

[ -f scripts/fan-control.sh ] || { echo "à lancer depuis la racine du dépôt" >&2; exit 1; }

step "0. Sauvegarde des versions en place"
$SSH 'mkdir -p /root/backup-preaudit
      for f in /usr/local/bin/fan-control.sh /usr/local/bin/nas-dashboard.py /etc/init.d/fan-control; do
          [ -f "$f" ] && cp -a "$f" /root/backup-preaudit/ && echo "  sauvé $f"
      done; true'

step "1. Correctif d'hystérésis du ventilateur + détection du dashboard"
scp -q scripts/fan-control.sh   "$NAS:/usr/local/bin/fan-control.sh"
scp -q scripts/webui.py         "$NAS:/usr/local/bin/nas-dashboard.py"
scp -q scripts/fan-control.init "$NAS:/etc/init.d/fan-control"
$SSH 'chmod +x /usr/local/bin/fan-control.sh /usr/local/bin/nas-dashboard.py /etc/init.d/fan-control'

step "1b. Élargissement de la zone morte"
# Seuils d'origine CONSERVÉS (38/46). Un essai à T_HIGH=50 a été mesuré puis
# abandonné : à 6000 RPM la carte se stabilise déjà à 50 °C, il n'y a aucune
# marge de refroidissement à récupérer. Relever le seuil laisse simplement la
# carte monter jusqu'à lui — disques passés de 38 à 43 °C — avant de repartir à
# fond quand même. Plus chaud, pas plus silencieux.
#
# Le battement ne venait pas des seuils mais de l'hystérésis : HYST=4 donne une
# zone morte 42-46 °C, ce qui suffit. Pour revenir aux défauts du daemon :
#   ssh NAS 'rm /etc/default/fan-control && service fan-control restart'
scp -q scripts/fan-control.default "$NAS:/etc/default/fan-control"
$SSH 'echo "  /etc/default/fan-control écrit"'

$SSH 'service fan-control restart >/dev/null 2>&1 || /etc/init.d/fan-control restart
      service nas-dashboard restart >/dev/null 2>&1 || /etc/init.d/nas-dashboard restart
      echo "  services redémarrés"'

step "2. Horloge persistante (fake-hwclock)"
# Sans RTC, chaque boot repart en 1969 : wtmp/last deviennent inutilisables pour
# dater un incident. Défaire : apt remove fake-hwclock
$SSH 'if dpkg -l fake-hwclock 2>/dev/null | grep -q "^ii"; then
          echo "  déjà installé"
      else
          apt-get update -qq && apt-get install -y -qq fake-hwclock && echo "  installé"
      fi
      fake-hwclock save 2>/dev/null && echo "  heure courante mémorisée" || true'

step "3. Erreurs de système de fichiers -> remontage en lecture seule"
# Par défaut « Continue » : une erreur FS laissait le NAS écrire par-dessus.
# Défaire : tune2fs -e continue /dev/sda1  (idem /dev/md0)
$SSH 'tune2fs -e remount-ro /dev/sda1 >/dev/null && echo "  / : remount-ro"
      tune2fs -e remount-ro /dev/md0  >/dev/null && echo "  /srv/data : remount-ro"
      tune2fs -l /dev/sda1 | grep -i "errors behavior"
      tune2fs -l /dev/md0  | grep -i "errors behavior"'

step "4. Surveillance SMART continue (smartd)"
# Disques à ~30 000 h : sans smartd, une dégradation ne se voit qu'à l'œil.
# Défaire : service smartd stop && update-rc.d smartd disable
# Deux pièges ici :
#  - le démon s'appelle smartd, mais Debian installe le service sous le nom du
#    paquet (/etc/init.d/smartmontools) ; viser « smartd » ne démarre rien ;
#  - la config livrée listait /dev/sde en dur, absent depuis le kernel 6.5.7
#    (README, Key Discovery #4), et smartd refuse de démarrer sur un device
#    manquant — d'où zéro surveillance depuis l'installation.
$SSH 'if [ ! -x /usr/sbin/smartd ]; then apt-get install -y -qq smartmontools; fi
      sed -i "s/^#*start_smartd=.*/start_smartd=yes/" /etc/default/smartmontools 2>/dev/null || true
      grep -q "^start_smartd=yes" /etc/default/smartmontools 2>/dev/null || \
          echo "start_smartd=yes" >> /etc/default/smartmontools
      [ -f /root/backup-preaudit/smartd.conf.orig ] || cp -a /etc/smartd.conf /root/backup-preaudit/smartd.conf.orig 2>/dev/null || true'
scp -q scripts/smartd.conf "$NAS:/etc/smartd.conf"
$SSH 'update-rc.d smartmontools defaults >/dev/null 2>&1 || true
      /etc/init.d/smartmontools restart >/dev/null 2>&1 || /etc/init.d/smartmontools start >/dev/null 2>&1 || true
      pgrep -l smartd || echo "  ATTENTION: smartd toujours pas lancé"'

step "5. Swap de secours (512 Mo)"
# 486 Mo de RAM sans swap : aucune marge si Samba + NFS + rebuild RAID coïncident.
# Sur / (sda1), surtout pas sur le RAID. Défaire :
#   swapoff /swapfile && rm /swapfile && sed -i /swapfile/d /etc/fstab
$SSH 'if [ -f /swapfile ]; then
          echo "  /swapfile existe déjà"
      else
          dd if=/dev/zero of=/swapfile bs=1M count=512 status=none
          chmod 600 /swapfile
          mkswap /swapfile >/dev/null
          echo "  /swapfile créé"
      fi
      swapon /swapfile 2>/dev/null || true
      grep -q "^/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
      free -m | grep -i swap'

step "6. Vérification"
$SSH 'echo "--- ventilateur ---"; tail -3 /var/log/fan-control.log
      echo "--- capteurs ---"
      for h in /sys/class/hwmon/hwmon*; do
          n=$(cat "$h/name" 2>/dev/null)
          [ -e "$h/temp1_input" ] && echo "  $n: $(cat "$h/temp1_input")"
          [ -e "$h/pwm1" ] && echo "  $n pwm1: $(cat "$h/pwm1") rpm: $(cat "$h/fan1_input" 2>/dev/null)"
      done'
echo
echo "--- services vus par le dashboard ---"
curl -s --max-time 8 "http://${NAS#*@}:8080/api/status" | tr ',' '\n' | grep -A1 -i 'name\|swap' | head -20 || true

echo
echo "Terminé. Surveiller /var/log/fan-control.log : le nombre de transitions"
echo "par jour doit s'effondrer (il montait à 580)."
