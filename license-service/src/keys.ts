/** Licence keys we mint ourselves, for comped, press and invoiced-team copies.
 *
 *  Format:  DP1-XXXX-XXXX-XXXX-XXXC
 *  where X is Crockford base32 (no I, L, O or U, so it survives being read
 *  aloud or retyped) and the final character is a mod-37 checksum. The `DP1-`
 *  prefix is what lets /v1/activate route a key to us instead of to Dodo
 *  without a database lookup.
 */

const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford base32
export const MANUAL_PREFIX = 'DP1-';

/** Crockford's canonical confusables, so `DP1-O0I1` typed by a human still works. */
const CONFUSABLES: Record<string, string> = {
  O: '0', o: '0',
  I: '1', i: '1', L: '1', l: '1',
  U: 'V', u: 'V',
};

const checksumChar = (body: string): string => {
  let sum = 0;
  for (const ch of body) sum = (sum * 31 + ALPHABET.indexOf(ch) + 1) % 37;
  return ALPHABET[sum % ALPHABET.length]!;
};

export function mintKey(): string {
  const bytes = new Uint8Array(15);
  crypto.getRandomValues(bytes);
  const body = [...bytes].map((b) => ALPHABET[b % ALPHABET.length]!).join('');
  const full = body + checksumChar(body);
  return MANUAL_PREFIX + (full.match(/.{1,4}/g) ?? []).join('-');
}

/** Uppercases, strips separators and repairs confusable characters. Returns the
 *  canonical form, or null if this is not a well-formed DP1 key. */
export function normaliseManualKey(input: string): string | null {
  const trimmed = input.trim().toUpperCase();
  if (!trimmed.startsWith(MANUAL_PREFIX)) return null;

  const body = [...trimmed.slice(MANUAL_PREFIX.length).replace(/[\s-]/g, '')]
    .map((ch) => CONFUSABLES[ch] ?? ch)
    .join('');

  if (body.length !== 16) return null;
  if ([...body].some((ch) => !ALPHABET.includes(ch))) return null;
  if (checksumChar(body.slice(0, 15)) !== body[15]) return null;

  return MANUAL_PREFIX + (body.match(/.{1,4}/g) ?? []).join('-');
}

export const isManualKey = (input: string): boolean =>
  input.trim().toUpperCase().startsWith(MANUAL_PREFIX);

/** Dodo issues UUID-shaped keys; we only trim and normalise case. */
export const normaliseKey = (input: string): string =>
  normaliseManualKey(input) ?? input.trim();
