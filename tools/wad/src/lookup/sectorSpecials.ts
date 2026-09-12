/** Vanilla Doom sector special-type numbers. */
const T: Record<number, string> = {
  1: "Light: blinks randomly",
  2: "Light: blinks fast (strobe)",
  3: "Light: blinks slow (strobe)",
  4: "Damage 20% per tic + light blinks fast",
  5: "Damage 10% per tic",
  7: "Damage 5% per tic",
  8: "Light: glows/oscillates",
  9: "Secret area (counts toward the level's secret tally)",
  10: "Door: closes 30 seconds after level start",
  11: "Damage 20% per tic; ends the level if health would drop to 10 or below",
  12: "Light: blinks slow (strobe), synchronized",
  13: "Light: blinks fast (strobe), synchronized",
  14: "Door: opens after 5 minutes",
  16: "Damage 20% per tic (heavy damage)",
  17: "Light: flickers randomly (fire flicker)",
};

export function sectorSpecialName(specialType: number): string {
  if (specialType === 0) return "No special";
  return T[specialType] ?? `Unknown/unmapped sector special ${specialType}`;
}
