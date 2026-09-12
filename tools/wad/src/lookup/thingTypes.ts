/**
 * Vanilla Doom "doomednum" thing types. Freedoom is a drop-in IWAD
 * replacement: it reuses the exact same doomednums (only the graphics/sounds
 * differ), so this table applies unchanged to `freedoom1.wad`.
 */
export type ThingCategory =
  | "player_start"
  | "monster"
  | "weapon"
  | "ammo"
  | "health"
  | "armor"
  | "key"
  | "decoration"
  | "other";

export interface ThingTypeInfo {
  name: string;
  category: ThingCategory;
}

const T: Record<number, ThingTypeInfo> = {
  1: { name: "Player 1 start", category: "player_start" },
  2: { name: "Player 2 start", category: "player_start" },
  3: { name: "Player 3 start", category: "player_start" },
  4: { name: "Player 4 start", category: "player_start" },
  11: { name: "Deathmatch start", category: "player_start" },
  14: { name: "Teleport landing", category: "other" },

  // Monsters
  3004: { name: "Zombieman (former human trooper)", category: "monster" },
  9: { name: "Shotgun guy (former sergeant)", category: "monster" },
  3001: { name: "Imp", category: "monster" },
  3002: { name: "Demon (pinky)", category: "monster" },
  58: { name: "Spectre", category: "monster" },
  3003: { name: "Baron of Hell", category: "monster" },
  3005: { name: "Cacodemon", category: "monster" },
  69: { name: "Hell knight", category: "monster" },
  64: { name: "Arch-vile", category: "monster" },
  65: { name: "Chaingunner (heavy weapon dude)", category: "monster" },
  66: { name: "Revenant", category: "monster" },
  67: { name: "Mancubus", category: "monster" },
  68: { name: "Arachnotron", category: "monster" },
  71: { name: "Pain elemental", category: "monster" },
  72: { name: "Wolfenstein SS", category: "monster" },
  7: { name: "Spider mastermind", category: "monster" },
  16: { name: "Cyberdemon", category: "monster" },
  84: { name: "Wolfenstein SS (alt)", category: "monster" },

  // Weapons
  2001: { name: "Shotgun", category: "weapon" },
  2002: { name: "Chaingun", category: "weapon" },
  2003: { name: "Rocket launcher", category: "weapon" },
  2004: { name: "Plasma rifle", category: "weapon" },
  2005: { name: "Chainsaw", category: "weapon" },
  2006: { name: "BFG9000", category: "weapon" },
  82: { name: "Super shotgun", category: "weapon" },

  // Ammo
  2007: { name: "Ammo clip (bullets)", category: "ammo" },
  2008: { name: "Shotgun shells", category: "ammo" },
  2010: { name: "Rocket", category: "ammo" },
  2046: { name: "Box of rockets", category: "ammo" },
  2047: { name: "Cell charge (energy)", category: "ammo" },
  17: { name: "Cell charge pack", category: "ammo" },
  2048: { name: "Box of bullets", category: "ammo" },
  2049: { name: "Box of shotgun shells", category: "ammo" },
  8: { name: "Backpack (doubles ammo capacity, gives ammo)", category: "ammo" },

  // Health
  2011: { name: "Stimpack", category: "health" },
  2012: { name: "Medikit", category: "health" },
  2013: { name: "Soulsphere", category: "health" },
  2014: { name: "Health bonus", category: "health" },
  83: { name: "Megasphere", category: "health" },

  // Armor
  2015: { name: "Armor bonus", category: "armor" },
  2018: { name: "Green armor", category: "armor" },
  2019: { name: "Blue armor (megaarmor)", category: "armor" },

  // Powerups
  2022: { name: "Invulnerability sphere", category: "other" },
  2023: { name: "Berserk pack", category: "other" },
  2024: { name: "Partial invisibility", category: "other" },
  2025: { name: "Radiation shielding suit", category: "other" },
  2026: { name: "Computer area map", category: "other" },
  2045: { name: "Light amplification visor", category: "other" },

  // Keys
  5: { name: "Blue keycard", category: "key" },
  13: { name: "Red keycard", category: "key" },
  6: { name: "Yellow keycard", category: "key" },
  40: { name: "Blue skull key", category: "key" },
  38: { name: "Red skull key", category: "key" },
  39: { name: "Yellow skull key", category: "key" },

  // Common decorations / obstacles. doomednum values and spawn-state-derived
  // names cross-checked against id Software's original linuxdoom-1.10
  // info.c (mobjinfo[] "doomednum" / "spawnstate" fields), which Freedoom
  // reuses unchanged.
  2035: { name: "Barrel (explosive)", category: "decoration" },
  2028: { name: "Floor lamp", category: "decoration" },
  85: { name: "Tall techno lamp", category: "decoration" },
  86: { name: "Short techno lamp", category: "decoration" },
  48: { name: "Tall techno pillar", category: "decoration" },
  30: { name: "Tall green pillar", category: "decoration" },
  32: { name: "Tall red pillar", category: "decoration" },
  31: { name: "Short green pillar", category: "decoration" },
  33: { name: "Short red pillar", category: "decoration" },
  36: { name: "Heart column", category: "decoration" },
  37: { name: "Skull column", category: "decoration" },
  41: { name: "Evil eye", category: "decoration" },
  42: { name: "Floating skull rock", category: "decoration" },
  43: { name: "Torch (burning tree stump)", category: "decoration" },
  44: { name: "Blue torch", category: "decoration" },
  45: { name: "Green torch", category: "decoration" },
  46: { name: "Red torch", category: "decoration" },
  55: { name: "Short blue torch", category: "decoration" },
  56: { name: "Short green torch", category: "decoration" },
  57: { name: "Short red torch", category: "decoration" },
  47: { name: "Stalagmite", category: "decoration" },
  34: { name: "Candle", category: "decoration" },
  35: { name: "Candelabra", category: "decoration" },
  25: { name: "Impaled human", category: "decoration" },
  26: { name: "Twitching (impaled human)", category: "decoration" },
  27: { name: "Head on a stick", category: "decoration" },
  28: { name: "Heads on a stick (multiple)", category: "decoration" },
  29: { name: "Head on a stick with candles", category: "decoration" },
  49: { name: "Hanging victim, twitching (bloody)", category: "decoration" },
  50: { name: "Hanging victim, gibbed (pose B)", category: "decoration" },
  51: { name: "Hanging victim, gibbed (pose C)", category: "decoration" },
  52: { name: "Hanging victim, gibbed (pose D)", category: "decoration" },
  53: { name: "Hanging victim, gibbed (pose E)", category: "decoration" },
  59: { name: "Hanging victim, gibbed (pose B, alt)", category: "decoration" },
  60: { name: "Hanging victim, gibbed (pose D, alt)", category: "decoration" },
  61: { name: "Hanging victim, gibbed (pose C, alt)", category: "decoration" },
  62: { name: "Hanging victim, gibbed (pose E, alt)", category: "decoration" },
  63: { name: "Hanging victim, twitching (bloody, alt)", category: "decoration" },
  70: { name: "Burning barrel", category: "decoration" },
  54: { name: "Large brown tree", category: "decoration" },
  10: { name: "Bloody mess (gibbed player, pose A)", category: "decoration" },
  12: { name: "Bloody mess (gibbed player, pose B)", category: "decoration" },
  24: { name: "Pile of skulls and gibs", category: "decoration" },
  15: { name: "Dead player", category: "decoration" },
  18: { name: "Dead zombieman", category: "decoration" },
  19: { name: "Dead shotgun guy", category: "decoration" },
  20: { name: "Dead imp", category: "decoration" },
  21: { name: "Dead demon", category: "decoration" },
  22: { name: "Dead cacodemon", category: "decoration" },
  23: { name: "Dead lost soul (invisible)", category: "decoration" },
  3006: { name: "Lost soul", category: "monster" },
};

export function thingTypeInfo(type: number): ThingTypeInfo {
  return T[type] ?? { name: `Unknown/unmapped thing type ${type}`, category: "other" };
}
