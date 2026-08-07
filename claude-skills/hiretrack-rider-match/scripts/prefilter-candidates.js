#!/usr/bin/env node
'use strict';

// Narrows the full HireTrack equipment catalog (7000+ Hetype rows) down to a
// short candidate list per rider line, using cheap token overlap. This is a
// pre-filter only - the actual pick (which candidate is the right match, and
// how confident) is made by Claude's own judgment over the shortlist, not by
// this script. Rider wording is too inconsistent (abbreviations, model-only
// lines, translated categories) for a fixed scoring formula to be the final
// word.

const fs = require('fs');

function readJsonArg(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function tokenize(text) {
  return String(text || '')
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9а-яё\s]/gi, ' ')
    .split(/\s+/)
    .filter((token) => token.length > 1);
}

function itemSearchText(item) {
  return [item.name, item.categoryName, item.shortcode, item.comments, item.longDescription]
    .filter(Boolean)
    .join(' ');
}

function scoreItem(lineTokenSet, item) {
  let score = 0;

  // Similars group name is a curated functional taxonomy ("vocal mic", "DI
  // box", "crash cymbal", ~48 groups total) - an overlap here is a much
  // stronger, cleaner signal than raw item-name text overlap, so it's scored
  // separately and weighted heavily.
  if (item.similarGroupName) {
    const groupTokens = tokenize(item.similarGroupName);
    if (groupTokens.length > 0) {
      const groupTokenSet = new Set(groupTokens);
      let groupOverlap = 0;
      for (const token of lineTokenSet) {
        if (groupTokenSet.has(token)) groupOverlap += 1;
      }
      if (groupOverlap > 0) {
        score += 3 * (groupOverlap / groupTokens.length);
      }
    }
  }

  const itemTokens = tokenize(itemSearchText(item));
  if (itemTokens.length > 0) {
    const itemTokenSet = new Set(itemTokens);
    let overlap = 0;
    for (const token of lineTokenSet) {
      if (itemTokenSet.has(token)) overlap += 1;
    }
    if (overlap > 0) {
      // Overlap relative to how specific the rider line is, plus a bonus for
      // exact substring hits in the item name (helps short model numbers
      // like "sm58" or "v8" that tokenize to very few tokens).
      score += overlap / lineTokenSet.size;
      const lowerName = String(item.name || '').toLowerCase();
      for (const token of lineTokenSet) {
        if (token.length >= 3 && lowerName.includes(token)) {
          score += 0.5;
        }
      }
    }
  }

  // Small nudge for Composite/Alias/Priced-Alias kit types (EquipmentType >
  // 0 - see TEquipmentType in the blueprint doc): these already bundle
  // related components, and are often the more correct single-line match
  // when a rider line describes a "kit"/"pair"/"system" rather than one
  // discrete piece - don't out-rank a genuinely better text match though.
  if (score > 0 && item.equipmentType) {
    score *= 1.05;
  }

  return score;
}

function main() {
  const [, , catalogPath, riderPath, topNArg] = process.argv;
  if (!catalogPath || !riderPath) {
    console.error('Usage: prefilter-candidates.js <catalog.json> <rider-lines.json> [topN]');
    process.exit(1);
  }
  const topN = Number(topNArg) || 8;

  const catalogRaw = readJsonArg(catalogPath);
  const catalog = Array.isArray(catalogRaw) ? catalogRaw : catalogRaw.items || [];
  const riderLines = readJsonArg(riderPath);

  const results = riderLines.map((line) => {
    const text = typeof line === 'string' ? line : line.text;
    const lineTokenSet = new Set(tokenize(text));

    const candidates = catalog
      .map((item) => ({ item, score: scoreItem(lineTokenSet, item) }))
      .filter((entry) => entry.score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, topN)
      .map(({ item, score }) => ({
        typeId: item.typeId,
        name: item.name,
        categoryName: item.categoryName,
        similarGroup: item.similarGroupName || null,
        equipmentType: item.equipmentType || 0,
        class: item.class,
        accessories: Array.isArray(item.accessories) && item.accessories.length > 0
          ? item.accessories.map((a) => ({
              subtypeId: a.subtypeId,
              subtypeName: a.subtypeName,
              quantity: a.quantity,
              required: a.required,
            }))
          : undefined,
        // Composite Kit "recipe" - what this type actually expands to (e.g.
        // a hi-hat pair type -> Top + Bottom). Only present for
        // equipmentType > 0.
        components: Array.isArray(item.components) && item.components.length > 0
          ? item.components.map((c) => ({
              componentTypeId: c.componentTypeId,
              componentName: c.componentName,
              quantity: c.quantity,
            }))
          : undefined,
        score: Math.round(score * 100) / 100,
      }));

    return { text, candidates };
  });

  process.stdout.write(JSON.stringify(results, null, 2));
}

main();
