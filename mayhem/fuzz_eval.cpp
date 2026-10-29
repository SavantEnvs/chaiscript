// Fuzz harness: evaluate arbitrary bytes as a ChaiScript program in a fresh engine.
// Ported from upstream's src/libfuzzer_client.cpp, minus its per-input result files (a fuzz target
// must not write to the filesystem) and minus the SHA3 bookkeeping that only named those files.
#include <chaiscript/chaiscript.hpp>

#include <cstddef>
#include <cstdint>
#include <string>

static const char *const kAssertPrelude = R"chaiscript(
def assert_equal(x, y)
{
  if (x == y)
  {
    // Passes
  } else {
    print("assert_equal failure: got '" + to_string(y) + "' expected '" + to_string(x) + "'");
  }
}

def assert_false(f)
{
  if (f)
  {
    print("assert_false failure");
  }
}

def assert_true(f)
{
  if (!f)
  {
    print("assert_true failure");
  }
}

def assert_not_equal(x, y)
{
  if (!(x == y))
  {
    // Passes
  } else {
    print("assert_not_equal failure: got " + to_string(y) + " which was not expected.");
  }
}

def assert_throws(desc, x)
{
  if (throws_exception(x))
  {
    // Passes
  } else {
    print("assert_throws failure, function did not throw exception: " + to_string(desc));
  }
})chaiscript";

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  chaiscript::ChaiScript chai;
  chai.eval(kAssertPrelude);

  try {
    chai.eval(std::string(reinterpret_cast<const char *>(data), size));
  } catch (const chaiscript::exception::eval_error &) {
  } catch (const chaiscript::Boxed_Value &) {
  } catch (const std::exception &) {
  } catch (...) {
  }

  return 0;
}
