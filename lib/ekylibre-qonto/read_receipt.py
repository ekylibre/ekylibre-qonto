#!/usr/bin/env python3
"""Reads a supplier document or a till receipt and prints what it says as JSON.

    python3 read_receipt.py <file>

Local only: PyMuPDF for the text of a PDF, tesseract (when installed) for a
picture or a scanned page. Nothing is sent anywhere. The result is a set of
hints (total, date, number, SIRET, VAT split); the caller decides what to do
with them.
"""
import json
import re
import subprocess
import sys

SPACE = r'[ \u00a0\u2009\u202f]'
AMOUNT = r'\d{1,3}(?:' + SPACE + r'|\.)\d{3}(?:[,.]\d{2})|\d+[,.]\d{2}'
TOTAL_KEYS = [
    r'total\s+ttc', r'net\s+[àa]\s+payer', r'total\s+[àa]\s+payer', r'montant\s+d[uû]',
    r'montant\s+ttc', r'montant\s+total', r'total\s+t\.?t\.?c', r'\btotal\b',
]
MIN_TEXT = 40


def number(text):
    text = re.sub(r'\s|\u00a0|\u2009|\u202f', '', text)
    if ',' in text:
        text = text.replace('.', '').replace(',', '.')
    return round(float(text), 2)


def text_of(path):
    """(text, method) — the embedded text, else OCR when the engine exists."""
    text = ''
    try:
        import fitz
        doc = fitz.open(path, filetype='pdf') if path.lower().endswith('.pdf') or is_pdf(path) else fitz.open(path)
        text = ''.join(page.get_text() for page in doc)
        if len(text.strip()) >= MIN_TEXT:
            return text, 'text'
        return ocr(doc), 'ocr'
    except Exception:
        return text, 'none'


def is_pdf(path):
    with open(path, 'rb') as handle:
        return handle.read(5) == b'%PDF-'


def ocr(doc):
    import fitz
    chunks = []
    for page in list(doc)[:3]:
        png = page.get_pixmap(dpi=200).tobytes('png')
        run = subprocess.run(['tesseract', 'stdin', 'stdout', '-l', 'fra+eng'], input=png, capture_output=True, timeout=60)
        chunks.append(run.stdout.decode('utf-8', 'ignore'))
    return '\n'.join(chunks)


def find_total(lines):
    for key in TOTAL_KEYS:
        for index, line in enumerate(lines):
            if re.search(key, line, re.I):
                amounts = re.findall(AMOUNT, line)
                # PyMuPDF often puts a label and its value in separate blocks.
                for ahead in lines[index + 1:index + 3]:
                    if not amounts:
                        amounts = re.findall(AMOUNT, ahead)
                if amounts:
                    return number(amounts[-1]), key
    return None, None


def total_candidates(lines):
    """Every amount written next to a 'total' label, whatever it is the total of
    (with or without VAT). The caller knows what was paid and keeps the one that fits."""
    found = []
    for index, line in enumerate(lines):
        if any(re.search(key, line, re.I) for key in TOTAL_KEYS):
            for chunk in [line] + lines[index + 1:index + 3]:
                found += [number(a) for a in re.findall(AMOUNT, chunk)]
    return sorted(set(found))


def find_vat_lines(lines):
    """Rows 'rate  HT  VAT  TTC' (a till receipt's VAT recap or an invoice's)."""
    found = []
    for line in lines:
        rate = re.search(r'(\d{1,2}(?:[,.]\d{1,3})?)\s*%', line)
        if not rate:
            continue
        amounts = [number(a) for a in re.findall(AMOUNT, line[rate.end():])]
        if len(amounts) >= 3:
            pretax, vat, total = amounts[-3:]
            if abs(pretax + vat - total) <= 0.02:
                found.append({'rate': float(rate.group(1).replace(',', '.')), 'pretax': pretax, 'vat': vat, 'total': total})
    return found


def find_date(text):
    for found in re.finditer(r'(?<!\d)(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4}|\d{2})(?!\d)', text):
        day, month, year = int(found.group(1)), int(found.group(2)), int(found.group(3))
        year += 2000 if year < 100 else 0
        if 1 <= day <= 31 and 1 <= month <= 12 and 2000 <= year <= 2100:
            return '%04d-%02d-%02d' % (year, month, day)
    found = re.search(r'(\d{4})-(\d{2})-(\d{2})', text)
    return found.group(0) if found else None


def find_siret(text):
    labelled = re.search(r'siret\W{0,3}((?:\d[ .]?){14})', text, re.I)
    if labelled:
        return re.sub(r'\D', '', labelled.group(1))
    bare = re.search(r'(?<!\d)(\d{3}[ .]?\d{3}[ .]?\d{3}[ .]?\d{5})(?!\d)', text)
    return re.sub(r'\D', '', bare.group(1)) if bare else None


def find_vat_number(text):
    found = re.search(r'\bFR\s?\d{2}\s?\d{3}\s?\d{3}\s?\d{3}\b', text)
    return re.sub(r'\s', '', found.group(0)) if found else None


def find_invoice_number(text):
    found = re.search(r'(?:facture|invoice)\s*(?:n[°ºo.]*|num[ée]ro|#)?\s*:?\s*([A-Z0-9][A-Z0-9\-_/]{2,})', text, re.I)
    if found and re.search(r'\d', found.group(1)):
        return found.group(1)
    return None


def read(path):
    text, method = text_of(path)
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    total, key = find_total(lines)
    vat_lines = find_vat_lines(lines)
    # A VAT split that adds up to the total is the strongest sign we read the right thing.
    consistent = bool(vat_lines) and total is not None and abs(sum(v['total'] for v in vat_lines) - total) <= 0.02
    return {
        'method': method, 'chars': len(text.strip()),
        'total': total, 'total_label': key, 'total_candidates': total_candidates(lines), 'date': find_date(text), 'number': find_invoice_number(text),
        'siret': find_siret(text), 'vat_number': find_vat_number(text),
        'vat_lines': vat_lines, 'vat_consistent': consistent,
    }


if __name__ == '__main__':
    print(json.dumps(read(sys.argv[1])))
