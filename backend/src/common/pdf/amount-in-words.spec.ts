import { amountInWords, integerInWords } from './amount-in-words';

describe('amountInWords', () => {
  it.each([
    [0, 'zéro'],
    [1, 'un'],
    [16, 'seize'],
    [21, 'vingt et un'],
    [71, 'soixante et onze'],
    [77, 'soixante-dix-sept'],
    [80, 'quatre-vingts'],
    [81, 'quatre-vingt-un'],
    [91, 'quatre-vingt-onze'],
    [99, 'quatre-vingt-dix-neuf'],
    [100, 'cent'],
    [200, 'deux cents'],
    [201, 'deux cent un'],
    [1000, 'mille'],
    [2000, 'deux mille'],
    [200000, 'deux cent mille'],
    [1250, 'mille deux cent cinquante'],
    [1000000, 'un million'],
    [2300000, 'deux millions trois cent mille'],
  ])('%i → %s', (value, words) => {
    expect(integerInWords(value)).toBe(words);
  });

  it('dinars et centimes, accords', () => {
    expect(amountInWords(125050)).toBe(
      'mille deux cent cinquante dinars et cinquante centimes',
    );
    expect(amountInWords(100)).toBe('un dinar');
    expect(amountInWords(101)).toBe('un dinar et un centime');
    expect(amountInWords(-500)).toBe('moins cinq dinars');
  });
});
