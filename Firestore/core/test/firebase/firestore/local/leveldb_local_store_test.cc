/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "Firestore/core/src/firebase/firestore/local/leveldb_persistence.h"
#include "Firestore/core/test/firebase/firestore/local/local_store_test.h"
#include "Firestore/core/test/firebase/firestore/local/persistence_testing.h"

namespace firebase {
namespace firestore {
namespace local {
namespace {

class TestHelper : public LocalStoreTestHelper {
 public:
  std::unique_ptr<Persistence> MakePersistence() override {
    return LevelDbPersistenceForTesting();
  }

  /** Returns true if the garbage collector is eager, false if LRU. */
  bool IsGcEager() const override {
    return false;
  }
};

std::unique_ptr<LocalStoreTestHelper> Factory() {
  return absl::make_unique<TestHelper>();
}

}  // namespace

INSTANTIATE_TEST_SUITE_P(LevelDbLocalStoreTest,
                         LocalStoreTest,
                         ::testing::Values(Factory));

}  // namespace local
}  // namespace firestore
}  // namespace firebase
