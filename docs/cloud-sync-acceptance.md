# Cloud sync: checklist di verifica con account reali

I test automatici usano servizi simulati. Questa lista serve a verificare, con account di prova veri, i casi che i test non possono coprire. Per ogni caso: **cosa fare**, **cosa deve succedere**. Se qualcosa non torna, annota provider, passo e testo esatto del messaggio.

## Prima di cominciare

- Usa account di prova e una o due riunioni brevi. Non farlo durante una registrazione o una trascrizione.
- Build di prova: `NO_INSTALL=1 ./build.sh`, poi apri `build/Overheard.app`. Chiudi prima l'app installata.
- Le chiavi OAuth stanno solo in `.env.local` (non versionato). Redirect Dropbox e Google: `http://127.0.0.1:53139/oauth2callback`.
- Tieni una copia delle riunioni che ti interessano: `~/Meetings`.
- Dove guardare il cestino: Drive → Cestino; Dropbox → File eliminati; OneDrive → Cestino; WebDAV → cartella `.overheard-trash/<data>/`; S3 → prefisso `<prefix>.trash/<data-ora>/`; cartella sincronizzata → Cestino del Mac.

## Casi da provare, per ogni provider

| # | Cosa fare | Cosa deve succedere |
|---|---|---|
| 1 | Collega l'account, attiva la sync, aspetta una riunione breve | La riunione compare nella cartella dell'app sul servizio, stato "Sincronizzata" |
| 2 | Durante l'upload di un audio lungo, spegni il Wi-Fi per un minuto, riaccendilo | Messaggio "Nessuna connessione", poi l'upload riprende da solo. Nessun file duplicato sul servizio |
| 3 | Dal sito del provider, revoca l'accesso di Overheard | Entro un minuto lo stato diventa "Accesso scaduto" con pulsante **Riconnetti**. Nessun tentativo continuo ogni minuto. Dopo Riconnetti la sync riparte |
| 4 | Sul servizio, cancella `transcript.md` di una riunione | La riunione mostra "Eliminata dal cloud". Il file **non** torna da solo. Dal menu: **Carica di nuovo sul cloud** lo rimette. Con **Rimuovi copia cloud…** resta solo sul Mac |
| 5 | Sposta una riunione nel Cestino dall'app | La finestra dice che le copie cloud vanno nel cestino del servizio. I file compaiono nel cestino del provider (vedi sopra). Overheard non lo svuota |
| 6 | Come 5, ma con il Wi-Fi spento, poi riaccendilo | I file vanno nel cestino del servizio appena torna la rete (la coda sopravvive anche a un riavvio dell'app) |
| 7 | Come 5, ma prima modifica un file della riunione dal sito | Quel file **non** viene cestinato: resta dov'è |
| 8 | Due Mac sullo stesso account: modifica lo stesso transcript su entrambi | Sul secondo compare una copia `transcript (conflicted copy …).md` con la versione del cloud. "Controlla copie in conflitto": **Usa la copia** o **Tieni entrambe**. Nulla viene sovrascritto senza avviso |
| 9 | "Libera spazio audio", poi apri il transcript e usa Scarica e riproduci | L'audio torna, si riproduce. Con poco spazio libero compare un messaggio chiaro, senza troncare registrazioni |
| 10 | Con l'audio liberato, usa Riprova trascrizione | Scarica solo l'audio, poi ritrascrive. Non parte nessuna copia verso un altro servizio |
| 11 | Aggiungi più segnalibri (⌃⌥M) durante una registrazione, poi sincronizza | La riunione sincronizza normalmente, senza "File non verificato" |
| 12 | Scollega l'account e ricollegane uno diverso | Nessuna mescolanza di dati; le riunioni del vecchio account chiedono di ricollegarlo prima di trasferirle |

## Solo per alcuni provider

- **WebDAV (Nextcloud, pCloud, NAS):** dopo il caso 5, controlla che esista `.overheard-trash/<data>/` con i file. Se il server non supporta `MOVE`, la rimozione deve **fallire con un messaggio** e il file deve restare.
- **S3 / R2 / B2 / Wasabi / MinIO:** dopo il caso 5, controlla `<prefix>.trash/`. Se la copia nel cestino fallisce (permessi, oggetto oltre 5 GB), l'originale deve restare. Con orologio del Mac sfasato di oltre 5 minuti deve comparire il messaggio sull'orologio.
- **Google Drive:** in app "Test" i refresh token scadono dopo 7 giorni: verifica il caso 3 dopo quel tempo. Una riunione spostata nel cestino di Drive dal sito deve mostrare "Eliminata dal cloud", non riapparire.
- **Dropbox / OneDrive:** caso 4 con un file cancellato dal sito.
- **Cartella locale dentro iCloud Drive o Dropbox/Drive desktop:** la riunione deve risultare caricata solo quando il client ha finito. Copie `nome (1).ext` o `nome (conflicted copy …)` create dal client compaiono in "Controlla copie in conflitto".

## Cosa non è ancora coperto (segnalami se lo incontri)

- Due Mac che modificano lo stesso file nello stesso istante: prima di ogni upload che sostituisce un file, Overheard ricontrolla che sul cloud ci sia ancora la versione appena vista (cartella locale: anche subito prima dello scambio). Resta una finestra di pochi istanti su Drive, Dropbox e OneDrive, dove la versione sovrascritta sopravvive solo nella cronologia versioni del servizio. Il caso normale (modifiche non simultanee) è gestito.
- Primo collegamento di due Mac alla stessa cartella iCloud ancora vuota: se uno dei due marker finisce in una "conflicted copy", il Mac perdente adotta la libreria sopravvissuta. Provalo solo se riesci a collegare i due Mac nello stesso momento; è raro da riprodurre.
## Casi in più da provare

| # | Cosa fare | Cosa deve succedere |
|---|---|---|
| 13 | Imposta "Conserva i meeting" a pochi giorni, modalità **elimina tutto**, con una riunione vecchia già caricata | La cartella va nel Cestino del Mac e le copie cloud nel cestino del servizio. In modalità **solo audio** con la sync attiva non succede nulla da questa impostazione |
| 14 | Cartella locale in iCloud Drive: "Ottimizza spazio" attivo, file offloaded, Wi-Fi spento, poi sync | Non resta appeso: dopo al più 3 minuti compare "iCloud non ha ancora scaricato il file" e "Interrompi" funziona; con il Wi-Fi di nuovo acceso riprende |
| 15 | Dropbox, due Mac: modifica lo stesso file quasi insieme | Il Mac che arriva dopo non sovrascrive: compare la copia in conflitto |
| 16 | MCP (Claude): chiedi `get_meeting` di una riunione con il testo archiviato nel cloud | Risponde "stored in the cloud: open the meeting in Overheard to download it", non "no transcript" |

## Limiti noti

- Drive e OneDrive: una versione che arriva nell'ultimo istante prima del commit può ancora essere sostituita; sopravvive solo nella cronologia versioni del servizio. Le loro API per le precondizioni di versione non sono state verificate con un account reale, quindi non le ho attivate alla cieca.
- OneDrive: le copie di conflitto `nome-host.ext` non sono riconosciute (troppo ambigue senza falsi positivi).
