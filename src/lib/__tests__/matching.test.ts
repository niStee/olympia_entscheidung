import {
  calculateScoreBreakdown,
  buildQuizResult,
} from "../matching";

const QUESTIONS = [
  { id: "q1", weight: 1 },
  { id: "q2", weight: 1 },
  { id: "q3", weight: 2 },
];

const QUESTIONS_WITH_DIRECTION = [
  { id: "q1", weight: 1, direction: "pro" as const },
  { id: "q2", weight: 1, direction: "contra" as const },
  { id: "q3", weight: 1, direction: "pro" as const },
];

describe("calculateScoreBreakdown", () => {
  it("returns 50 when all questions are skipped", () => {
    const result = calculateScoreBreakdown({}, {}, QUESTIONS);
    expect(result.normalizedPercent).toBe(50);
    expect(result.answeredCount).toBe(0);
    expect(result.skippedCount).toBe(3);
  });

  it("returns 100 when all answers are 'agree' with normal relevance", () => {
    const answers = { q1: "agree" as const, q2: "agree" as const, q3: "agree" as const };
    const result = calculateScoreBreakdown(answers, {}, QUESTIONS);
    expect(result.normalizedPercent).toBe(100);
  });

  it("returns 0 when all answers are 'disagree' with normal relevance", () => {
    const answers = { q1: "disagree" as const, q2: "disagree" as const, q3: "disagree" as const };
    const result = calculateScoreBreakdown(answers, {}, QUESTIONS);
    expect(result.normalizedPercent).toBe(0);
  });

  it("returns 50 when all answers are 'neutral'", () => {
    const answers = { q1: "neutral" as const, q2: "neutral" as const, q3: "neutral" as const };
    const result = calculateScoreBreakdown(answers, {}, QUESTIONS);
    expect(result.normalizedPercent).toBe(50);
  });

  it("doubles the contribution of 'important' questions", () => {
    const answers = { q1: "agree" as const, q2: "skip" as const, q3: "skip" as const };
    const normalResult = calculateScoreBreakdown(answers, { q1: "normal" }, QUESTIONS);
    const importantResult = calculateScoreBreakdown(answers, { q1: "important" }, QUESTIONS);
    // Both should be 100% since it's the only answered question
    expect(normalResult.normalizedPercent).toBe(100);
    expect(importantResult.normalizedPercent).toBe(100);
    // But raw score should differ
    expect(importantResult.rawScore).toBe(normalResult.rawScore * 2);
  });

  it("handles mixed answers correctly", () => {
    const answers = { q1: "agree" as const, q2: "disagree" as const };
    const result = calculateScoreBreakdown(answers, {}, QUESTIONS);
    // q1: +2*1=+2, q2: -2*1=-2 → raw=0, max=4, min=-4 → (0-(-4))/(4-(-4))=4/8=50%
    expect(result.normalizedPercent).toBe(50);
    expect(result.rawScore).toBe(0);
  });

  it("applies question weight correctly (q3 has weight 2)", () => {
    const answers = { q3: "agree" as const };
    const result = calculateScoreBreakdown(answers, {}, QUESTIONS);
    // q3: +2 * weight(2) * relevance(1) = +4, max=+4, min=-4 → (4-(-4))/(4-(-4))=100%
    expect(result.normalizedPercent).toBe(100);
    expect(result.rawScore).toBe(4);
    expect(result.answeredCount).toBe(1);
    expect(result.skippedCount).toBe(2);
  });

  it("lean-agree and lean-disagree are halfway points", () => {
    const allLeanAgree = { q1: "lean-agree" as const, q2: "lean-agree" as const, q3: "lean-agree" as const };
    const result = calculateScoreBreakdown(allLeanAgree, {}, QUESTIONS);
    // All lean-agree: +1 each (weighted), normalized = 75%
    expect(result.normalizedPercent).toBe(75);
  });

  it("result label is descriptive and not empty", () => {
    const result = calculateScoreBreakdown(
      { q1: "agree" as const },
      {},
      QUESTIONS
    );
    expect(result.label).toBeTruthy();
    expect(typeof result.label).toBe("string");
  });

  it("buildQuizResult includes completedAt timestamp", () => {
    const result = buildQuizResult({}, {}, QUESTIONS);
    expect(result.completedAt).toBeTruthy();
    expect(new Date(result.completedAt).getTime()).not.toBeNaN();
  });

  it("score is always between 0 and 100", () => {
    const extremes = [
      { q1: "agree" as const, q2: "agree" as const, q3: "agree" as const },
      { q1: "disagree" as const, q2: "disagree" as const, q3: "disagree" as const },
    ];
    for (const answers of extremes) {
      const r = calculateScoreBreakdown(answers, {}, QUESTIONS);
      expect(r.normalizedPercent).toBeGreaterThanOrEqual(0);
      expect(r.normalizedPercent).toBeLessThanOrEqual(100);
    }
  });

  // --- Direction tests ---

  it("contra question with agree should decrease score (not increase)", () => {
    // q2 is contra: agree on contra should invert to -2, giving 0%
    const answers = { q2: "agree" as const };
    const result = calculateScoreBreakdown(answers, {}, QUESTIONS_WITH_DIRECTION);
    // contra agree: baseScore=2, directed=-2, raw=-2, max=2, min=-2 → (-2-(-2))/(2-(-2))=0/4=0%
    expect(result.normalizedPercent).toBe(0);
  });

  it("mixed pro/contra questions cancel out correctly", () => {
    // q1 (pro) agree = +2, q2 (contra) agree = -2 → raw=0 → 50%
    const answers = { q1: "agree" as const, q2: "agree" as const };
    const result = calculateScoreBreakdown(answers, {}, QUESTIONS_WITH_DIRECTION);
    expect(result.normalizedPercent).toBe(50);
    expect(result.rawScore).toBe(0);
  });

  it("all-contra agree should give 0%", () => {
    const allContra = [
      { id: "c1", weight: 1, direction: "contra" as const },
      { id: "c2", weight: 1, direction: "contra" as const },
    ];
    const answers = { c1: "agree" as const, c2: "agree" as const };
    const result = calculateScoreBreakdown(answers, {}, allContra);
    // Both contra agree: directed = -2 each, raw=-4, max=4, min=-4 → (-4-(-4))/(4-(-4))=0/8=0%
    expect(result.normalizedPercent).toBe(0);
  });

  it("direction undefined defaults to pro behavior", () => {
    // QUESTIONS has no direction field → should default to pro
    const answers = { q1: "agree" as const };
    const result = calculateScoreBreakdown(answers, {}, QUESTIONS);
    expect(result.normalizedPercent).toBe(100);
  });
});
