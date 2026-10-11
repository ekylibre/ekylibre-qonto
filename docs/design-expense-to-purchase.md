# Conception : des dépenses Qonto aux achats Ekylibre

Statut : proposition, rien n'est implémenté. Fait suite à la mesure du 2026-10-11 sur le tenant `admin`.

## 1. Constat qui oriente la conception
Sur 1 122 dépenses Qonto, 96 ne sont pas rapprochées (90 en 2026). Pour ces 96 :
F1 (facture Qonto liée) 10, F3 (modèle du dernier achat du tiers) 60 de plus, rien 26, F2 (achat existant) 0.
Le tiers est retrouvé pour 70 lignes, presque toujours par le libellé bancaire appris des rapprochements passés.
Le dernier achat d'un fournisseur reprend la nature habituelle dans 48 cas sur 48, comptes 41/48, taxes 40/48.
480 achats sur 547 n'ont qu'une ligne.

Conséquence : le cœur est un **suggéreur** (facture Qonto, sinon historique), pas un OCR. La création reste dans le
formulaire existant « Nouvel achat » du rapprochement (`Backend::QuickPurchasesController`), qui crée déjà
l'achat, le paiement et le lettrage. On ne duplique pas cette logique.

## 2. Principes
- **P1** Toujours validé par l'utilisateur : le suggéreur préremplit, il ne crée jamais.
- **P2** Chaque champ garde son origine (`source`) et une confiance : l'écran les montre.
- **P3** Aucune écriture chez Qonto. L'OCR est local.
- **P4** Idempotent : le suggéreur est pur (aucun effet), la finalisation est rejouable.
- **P5** Les garde-fous existants servent tels quels : `OwnCompany`, `PurchaseDuplicates`, `InboundDuplicates`.

## 3. Vue d'ensemble
```
 BankStatementItem (débit, non lettré)
          │
          ▼
 Qonto::ExpenseSuggester ──► Qonto::ExpenseSuggestion (valeur)
   │ 1 InboundMatch        facture Qonto liée (matched_transactions)        → F1
   │ 2 ExistingPurchase    achat non soldé même tiers/TTC (garde-fou)        → F2
   │ 3 SupplierModel       SupplierResolver + dernier achat / règle         → F3
   │ 4 ReceiptReader       PyMuPDF sur le justificatif (phase 3, lecture)   → F5
          │
          ▼
 Écran plugin « Dépenses à justifier »  (GET qonto/expenses)
          │  [Créer l'achat]  lien vers le formulaire du cœur, prérempli
          ▼
 Backend::QuickPurchasesController#new  (cœur, accepte un préremplissage)
          │  create : achat + paiement + lettrage (déjà existant)
          ▼  redirect=
 Qonto::ExpensesController#finalize  → Qonto::ExpenseFinalizer
          • joint le justificatif à l'achat   • clôt la facture reçue
          • mémorise le tiers/modèle (règle)  • rien si la ligne n'est pas lettrée
```

## 4. Composants (plugin `ekylibre-qonto`)

### 4.1 `Qonto::ExpenseSuggestion` (valeur immuable)
```ruby
Suggestion = Struct.new(
  :item,            # BankStatementItem
  :source,          # :inbound_invoice | :existing_purchase | :supplier_model | :receipt | :none
  :confidence,      # :high | :medium | :low
  :supplier,        # Entity | nil          ; supplier_how : :rule | :learned | :iban | :name
  :nature_id, :invoiced_at, :reference_number, :description,
  :items,           # [{variant_id:, conditioning_unit_id:, tax_id:, quantity:, unit_pretax_amount:, amount:}]
  :document,        # Document | nil (justificatif à joindre)
  :inbound,         # Qonto::InboundInvoice | nil
  :existing,        # Purchase | nil (F2)
  :warnings,        # [:own_company, :possible_duplicate, :amount_mismatch, :no_supplier ...]
  :provenance       # { field => :qonto | :inbound | :history | :rule | :receipt }
)
```
`ready?` = fournisseur + nature + au moins une ligne dont le TTC total égale le débit à 0,01 près.

### 4.2 `Qonto::ExpenseSuggester.call(item, context:)`
Chaîne de stratégies, la première qui fournit un fournisseur gagne, les suivantes complètent les champs vides :
1. **InboundMatch** (F1) : `InboundInvoice` dont `payload.matched_transactions[].transaction_id` = `item.provider[:id]`,
   non liée à un achat. Reprend fournisseur, numéro, date, lignes (XML), document. Appelle `OwnCompany`.
   Facture « avoir » ou kind `receipt`/`other` : suggestion `none` avec avertissement.
2. **ExistingPurchase** (F2) : `PurchaseInvoice` non soldé, même tiers (ou, sans tiers, même TTC à 0,01 et ±60 jours).
   Ne crée pas : la suggestion devient « rattacher l'achat X » (le formulaire du cœur sait le faire : `use_existing_trade`).
3. **SupplierModel** (F3) : `SupplierResolver` puis `LastPurchaseTemplate`.
4. **ReceiptReader** (phase 3) : complète date, numéro, TTC, ventilation TVA, SIRET ; n'écrase jamais les sources 1 à 3.

### 4.3 `Qonto::SupplierResolver`
Ordre, première correspondance non ambiguë :
1. règle explicite (`ExpenseRule`, §5) ;
2. appris : tiers (`payee`) des paiements déjà lettrés avec une ligne de même libellé normalisé, puis de même IBAN
   (lettrage : `JournalEntryItem.where(account_id:, letter:)` → `entry.resource` `OutgoingPayment`) ;
3. IBAN de la contrepartie = `Entity#iban` ;
4. `clean_counterparty_name` puis libellé = `Entity#full_name` normalisé, unique.
Ambiguïté (plusieurs tiers à égalité) : pas de tiers, avertissement `no_supplier`.
Les index « libellé → tiers » sont construits une fois par appel de liste (un seul parcours des lignes lettrées).

### 4.4 `Qonto::LastPurchaseTemplate`
Source : règle du tiers sinon dernier `PurchaseInvoice` du tiers (par `invoiced_at`). Reprend `nature_id` et, pour
chaque ligne distincte (compte, taxe, variante), le modèle. Montants recalculés pour égaler le débit :
- une seule ligne : quantité 1, `unit_pretax_amount` = TTC / (1 + taux) ;
- `vat_details` Qonto présent : une ligne par taux, HT/TVA tels que Qonto les donne ;
- plusieurs lignes dans le modèle : on garde les proportions du dernier achat, avertissement `amount_mismatch` si l'écart
  d'arrondi dépasse 0,01.
Sans achat antérieur pour le tiers : pas de modèle, la suggestion garde le tiers seulement.

### 4.5 Écran `Qonto::ExpensesController#index`
Liste des dépenses non lettrées, filtres par exercice (comme la boîte), type (carte, prélèvement, virement),
source de suggestion, confiance. Par ligne : date, libellé, montant, tiers proposé (+ origine), nature, source,
avertissements, justificatif (lien), actions :
- **Créer l'achat** : lien GET vers `new_backend_quick_purchase_path` avec `bank_statement_item_ids`, `nature_id`,
  `redirect` = `finalize` du plugin, et le préremplissage (§6) ;
- **Rattacher à l'achat X** (F2) ;
- **Ignorer** (frais bancaires, virements internes…) → table `qonto_expense_reviews` (statut `ignored`) ;
- **Mémoriser une règle** (case à cocher à la validation, phase 2).
Les frais Qonto (`qonto_fee`) et les virements internes sont ignorés d'office dans la liste par défaut.

### 4.6 `Qonto::ExpenseFinalizer` (idempotent)
Appelé en redirection après création et rejoué à l'ouverture de l'écran. Pour une ligne lettrée sans traitement :
retrouve l'achat par le lettrage (`entry.resource` → affaire → `PurchaseInvoice`), joint `suggestion.document` s'il n'y
est pas, lie `inbound.purchase_id` + statut `matched`, enregistre ou met à jour la règle du tiers. Ne fait rien si la
ligne n'est pas lettrée.

## 5. Données
Phase 0, prérequis (déjà proposé) : l'import des transactions garde dans `provider.data` `clean_counterparty_name`,
`counterparty_iban`, `counterparty_bic`, `unique_mandate_reference`, `vat_amount`, `vat_details`,
`cashflow_category`, `note`, `card_last_digits` et demande `includes[]=vat_details,labels,attachments`. Le suggéreur
lit ces champs ; sans eux il retombe sur le libellé et l'appel API en direct (plus lent).

Nouvelles tables du plugin (migrations du plugin, pas du cœur) :
```
qonto_expense_rules   id, match_kind (label|iban|counterparty), match_value, entity_id, purchase_nature_id,
                      variant_id, tax_id, account_id nullable, uses_count, last_used_at, timestamps
                      unique (match_kind, match_value)
qonto_expense_reviews id, bank_statement_item_id (unique), status (ignored|done), timestamps
```
Une règle ne remplace pas l'historique : elle passe en premier, l'historique couvre tout le reste.

## 6. Changement dans le cœur (minimal)
`Backend::QuickAffairsController#new` accepte un préremplissage en liste blanche :
`trade[reference_number|description|invoiced_at|nature_id]`, `trade[items_attributes][]`
(`variant_id`, `conditioning_unit_id`, `conditioning_quantity`, `tax_id`, `unit_pretax_amount`, `amount`) et
`affair[third_id]`. Sans ces paramètres, le comportement actuel est inchangé. Ni modèle ni schéma ne changent.
Phase suivante (optionnelle) : un point d'extension pour que le menu « Nouvel achat » du rapprochement bancaire
propose le préremplissage sans passer par l'écran du plugin.

## 7. Phases
| Phase | Contenu | Gain mesuré sur `admin` |
|---|---|---|
| 0 | Import enrichi des transactions + `includes[]` | prérequis |
| 1 | Suggéreur F1 + F2 (garde-fou) + écran + préremplissage cœur + finalisation | 10 lignes |
| 2 | F3 : résolveur, modèle du dernier achat, règles simples, « Ignorer » | + 60 lignes |
| 3 | Lecture des justificatifs en local (PyMuPDF) | couvre une partie des 26 restantes |

## 8. Lecture locale des justificatifs (phase 3)
PyMuPDF lit le texte des PDF qui en ont un (factures, PDF probants Qonto). Une photo (`.jpg`) n'a pas de texte :
il faudra un moteur d'OCR en plus (Tesseract ou équivalent), à décider. Exécution en tâche de fond : sous-processus
`python3 -I script.py <fichier>` (sans réseau, sans droit d'écriture), résultat JSON (`total`, `date`, `number`,
`siret`, `vat_lines[]`, chaque champ avec une confiance), mis en cache sur le `Document`. Le texte lu sert à confirmer
ou compléter, jamais à écraser une valeur de Qonto ou de l'historique. L'image Docker du plugin ajoute PyMuPDF.

## 9. Tests
- Suggéreur : une table de cas par stratégie (F1 liée, avoir, F2, F3 avec 1 et plusieurs lignes, tiers ambigu, sans
  historique) et la règle « somme TTC = débit ».
- Résolveur : libellé appris, IBAN, nom, ambiguïté.
- Finalizer : idempotence, ligne non lettrée, retrouver l'achat par lettrage.
- Contrôleur du cœur : sans paramètres inchangé ; avec paramètres préremplit ; paramètres hors liste blanche ignorés.
- Écran : filtres, ignoré d'office pour `qonto_fee`, avertissements, aucune création sans clic.

## 10. Critères d'acceptation
- Une dépense avec facture Qonto liée ouvre le formulaire d'achat rempli (tiers, numéro, date, lignes, TTC = débit).
- Une dépense d'un tiers connu ouvre le formulaire rempli d'après son dernier achat, TTC = débit.
- Aucun achat n'est créé tant que l'utilisateur n'a pas validé le formulaire.
- Valider crée achat, paiement et lettrage (comportement du cœur), le justificatif est joint, la facture reçue est close.
- Rejouer la finalisation ne crée rien de plus.
- Une facture de la société ou un doublon d'achat est signalé et ne peut pas être créé sans confirmation.

## 11. Risques
- **Lettrage** : retrouver l'achat après création repose sur le lettrage ; à vérifier sur un cas réel avant la phase 1.
- **Règles** : une règle fausse se propage. Elle est visible et modifiable, et l'usage compte (`uses_count`).
- **Arrondis** : une ligne unique recalculée depuis le TTC peut s'écarter d'un centime de la TVA saisie par Qonto ;
  dans ce cas on garde le montant HT de Qonto.
- **Photos** : sans moteur d'OCR, les justificatifs image restent à saisir à la main.
- **Données personnelles** : le texte lu est stocké avec le document, sur le serveur de l'exploitation seulement.
