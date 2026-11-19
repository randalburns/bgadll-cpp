// Unit tests of the sampler's fast paths against the plain versions they replace:
//   shuffle_prefix (the first m entries of the shuffle) against shuffle() itself;
//   combination_mask (branch-free unranking) against combination_at.
// Built by `./build.sh test` with the library's flags, so it tests the vector code the
// library was built with (shuffle_simd()). Exit status 0 when every case matches.
#include <cstdio>
#include <random>
#include <vector>

#include "model.hpp"

using namespace bga;

namespace {

int test_shuffle_prefix() {
  std::mt19937 g(42);
  int bad = 0, tests = 0;
  auto check = [&](int n, uint32_t seed, int m) {
    std::vector<int> a(static_cast<size_t>(n));
    for (int i = 0; i < n; i++) a[size_t(i)] = i;
    CrossPlatformRandom r{int(seed)};
    shuffle(a, n, r);
    std::vector<int> p(static_cast<size_t>(m));
    shuffle_prefix(n, seed, m, p.data());
    tests++;
    for (int j = 0; j < m; j++)
      if (p[size_t(j)] != a[size_t(j)]) {
        std::printf("shuffle_prefix: n=%d seed=%u m=%d differs at %d\n", n, seed, m, j);
        bad++;
        return;
      }
  };
  for (int it = 0; it < 400; it++) {
    const int n = 2 + int(g() % (it < 300 ? 5000u : 200000u));
    check(n, g(), 1 + int(g() % uint32_t(std::min(n, 3000))));
  }
  check(10400600, 12345u, 4096);  // C(26,13), the first trick
  std::printf("shuffle_prefix: %d/%d match shuffle\n", tests - bad, tests);
  return bad;
}

int test_combination_mask() {
  std::mt19937_64 g(7);
  Mask bits[52];
  for (int i = 0; i < 52; i++) bits[i] = Mask(1) << ((i * 7) % 64);
  long bad = 0, tests = 0;
  for (int n = 1; n <= 26; n++)
    for (int k = 0; k <= n; k++) {
      const int64_t total = binomial(n, k);
      for (int rep = 0; rep < 2000; rep++) {
        const int64_t idx = total <= 2000 ? rep % total : int64_t(g() % uint64_t(total));
        uint8_t set[52];
        combination_at(n, k, idx, set);
        Mask want = 0;
        for (int j = 0; j < k; j++) want |= bits[set[j] - 1];
        tests++;
        if (combination_mask(n, k, idx, bits) != want) bad++;
      }
    }
  std::printf("combination_mask: %ld/%ld match combination_at\n", tests - bad, tests);
  return int(bad != 0);
}

}  // namespace

int main() {
  std::printf("vector code: %s\n", shuffle_simd());
  const int bad = test_shuffle_prefix() + test_combination_mask();
  std::printf(bad ? "FAILED\n" : "all tests pass\n");
  return bad ? 1 : 0;
}
