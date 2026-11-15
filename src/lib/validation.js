import { fail } from './errors.js';
export const phoneValue = (input) => {
  const value = String(input || '').replace(/[\s()+-]/g, '');
  const phone = value.length === 12 && value.startsWith('91') ? value.slice(2) : value;
  if (!/^[6-9]\d{9}$/.test(phone)) fail('Enter a valid Indian mobile number.');
  return phone;
};
export const text = (value, min, max, label) => {
  const result = String(value || '').trim();
  if (result.length < min || result.length > max)
    fail(`${label} must have ${min}–${max} characters.`);
  return result;
};

export function requireMatchingProfileName(savedName, submittedName) {
  const normalize = (name) => name.normalize('NFC').trim().replace(/\s+/g, ' ').toLowerCase();
  if (normalize(savedName) !== normalize(submittedName))
    fail('Name and mobile number do not match. Enter the name saved on your profile.', 401);
}
