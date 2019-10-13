/*
 * Copyright 2018 Google
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

#include "Firestore/core/src/firebase/firestore/remote/remote_objc_bridge.h"

#import <Foundation/Foundation.h>

#include <map>

#import "Firestore/Protos/objc/google/firestore/v1/Firestore.pbobjc.h"
#import "Firestore/Source/API/FIRFirestore+Internal.h"

#include "Firestore/core/src/firebase/firestore/model/document_key.h"
#include "Firestore/core/src/firebase/firestore/model/maybe_document.h"
#include "Firestore/core/src/firebase/firestore/model/snapshot_version.h"
#include "Firestore/core/src/firebase/firestore/nanopb/byte_string.h"
#include "Firestore/core/src/firebase/firestore/nanopb/nanopb_util.h"
#include "Firestore/core/src/firebase/firestore/nanopb/writer.h"
#include "Firestore/core/src/firebase/firestore/remote/grpc_util.h"
#include "Firestore/core/src/firebase/firestore/remote/watch_change.h"
#include "Firestore/core/src/firebase/firestore/util/error_apple.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"
#include "Firestore/core/src/firebase/firestore/util/status.h"
#include "Firestore/core/src/firebase/firestore/util/statusor.h"
#include "Firestore/core/src/firebase/firestore/util/string_apple.h"
#include "grpcpp/support/status.h"

namespace firebase {
namespace firestore {
namespace remote {

using core::DatabaseInfo;
using local::QueryData;
using model::DocumentKey;
using model::MaybeDocument;
using model::Mutation;
using model::MutationResult;
using model::TargetId;
using model::SnapshotVersion;
using nanopb::ByteString;
using nanopb::ByteStringWriter;
using nanopb::MakeByteString;
using nanopb::MakeNSData;
using nanopb::MaybeMessage;
using nanopb::Message;
using remote::Serializer;
using util::MakeString;
using util::MakeNSError;
using util::Status;
using util::StatusOr;
using util::StringFormat;

namespace {

NSData* ConvertToNsData(const grpc::ByteBuffer& buffer, NSError** out_error) {
  std::vector<grpc::Slice> slices;
  grpc::Status status = buffer.Dump(&slices);
  if (!status.ok()) {
    *out_error = MakeNSError(Status{
        Error::Internal, "Trying to convert an invalid grpc::ByteBuffer"});
    return nil;
  }

  if (slices.size() == 1) {
    return [NSData dataWithBytes:slices.front().begin()
                          length:slices.front().size()];
  } else {
    NSMutableData* data = [NSMutableData dataWithCapacity:buffer.Length()];
    for (const auto& slice : slices) {
      [data appendBytes:slice.begin() length:slice.size()];
    }
    return data;
  }
}

template <typename T, typename U>
std::string DescribeMessage(const Message<U>& message) {
  // TODO(b/142276128): implement proper pretty-printing using just Nanopb.
  // Converting to an Objective-C proto just to be able to call `description` is
  // a hack.
  auto bytes = message.ToByteBuffer();
  auto ns_data = ConvertToNsData(bytes, nil);
  T* objc_request = [T parseFromData:ns_data error:nil];
  return util::MakeString([objc_request description]);
}

}  // namespace

// WatchStreamSerializer

WatchStreamSerializer::WatchStreamSerializer(Serializer serializer)
    : serializer_{std::move(serializer)} {
}

Message<google_firestore_v1_ListenRequest>
WatchStreamSerializer::EncodeWatchRequest(const QueryData& query) const {
  Message<google_firestore_v1_ListenRequest> result{
      google_firestore_v1_ListenRequest_fields};
  auto& request = *result;

  request.database = serializer_.EncodeDatabaseName();
  request.which_target_change =
      google_firestore_v1_ListenRequest_add_target_tag;
  request.add_target = serializer_.EncodeTarget(query);

  auto labels = serializer_.EncodeListenRequestLabels(query);
  if (!labels.empty()) {
    request.labels_count = nanopb::CheckedSize(labels.size());
    request.labels = MakeArray<google_firestore_v1_ListenRequest_LabelsEntry>(
        request.labels_count);

    pb_size_t i = 0;
    for (const auto& label : labels) {
      request.labels[i] = label;
      ++i;
    }
  }

  return result;
}

Message<google_firestore_v1_ListenRequest>
WatchStreamSerializer::EncodeUnwatchRequest(TargetId target_id) const {
  Message<google_firestore_v1_ListenRequest> result{
      google_firestore_v1_ListenRequest_fields};
  auto& request = *result;

  request.database = serializer_.EncodeDatabaseName();
  request.which_target_change =
      google_firestore_v1_ListenRequest_remove_target_tag;
  request.remove_target = target_id;

  return result;
}

MaybeMessage<google_firestore_v1_ListenResponse>
WatchStreamSerializer::DecodeResponse(const grpc::ByteBuffer& message) const {
  return Message<google_firestore_v1_ListenResponse>::TryDecode(message);
}

std::unique_ptr<WatchChange> WatchStreamSerializer::ToWatchChange(
    const google_firestore_v1_ListenResponse& response) const {
  nanopb::Reader reader;
  return serializer_.DecodeWatchChange(&reader, response);
}

SnapshotVersion WatchStreamSerializer::ToSnapshotVersion(
    const google_firestore_v1_ListenResponse& response) const {
  nanopb::Reader reader;
  return serializer_.DecodeVersionFromListenResponse(&reader, response);
}

std::string WatchStreamSerializer::Describe(
    const Message<google_firestore_v1_ListenRequest>& request) {
  return DescribeMessage<GCFSListenRequest>(request);
}

std::string WatchStreamSerializer::Describe(
    const Message<google_firestore_v1_ListenResponse>& response) {
  return DescribeMessage<GCFSListenResponse>(response);
}

// WriteStreamSerializer

WriteStreamSerializer::WriteStreamSerializer(Serializer serializer)
    : serializer_{std::move(serializer)} {
}

Message<google_firestore_v1_WriteRequest>
WriteStreamSerializer::EncodeHandshake() const {
  Message<google_firestore_v1_WriteRequest> result{
      google_firestore_v1_WriteRequest_fields};
  auto& request = *result;

  // The initial request cannot contain mutations, but must contain a project
  // ID.
  request.database = serializer_.EncodeDatabaseName();

  return result;
}

Message<google_firestore_v1_WriteRequest>
WriteStreamSerializer::EncodeWriteMutationsRequest(
    const std::vector<Mutation>& mutations,
    const ByteString& last_stream_token) const {
  Message<google_firestore_v1_WriteRequest> result{
      google_firestore_v1_WriteRequest_fields};
  auto& request = *result;

  if (!mutations.empty()) {
    request.writes_count = nanopb::CheckedSize(mutations.size());
    request.writes = MakeArray<google_firestore_v1_Write>(request.writes_count);

    for (pb_size_t i = 0; i != request.writes_count; ++i) {
      request.writes[i] = serializer_.EncodeMutation(mutations[i]);
    }
  }

  request.stream_token = nanopb::CopyBytesArray(last_stream_token.get());

  return result;
}

MaybeMessage<google_firestore_v1_WriteResponse>
WriteStreamSerializer::DecodeResponse(const grpc::ByteBuffer& message) const {
  return Message<google_firestore_v1_WriteResponse>::TryDecode(message);
}

model::SnapshotVersion WriteStreamSerializer::ToCommitVersion(
    const google_firestore_v1_WriteResponse& proto) const {
  nanopb::Reader reader;
  auto result = serializer_.DecodeVersion(&reader, proto.commit_time);
  return result;
}

std::vector<MutationResult> WriteStreamSerializer::ToMutationResults(
    const google_firestore_v1_WriteResponse& proto) const {
  const SnapshotVersion commit_version = ToCommitVersion(proto);

  const google_firestore_v1_WriteResult* writes = proto.write_results;
  pb_size_t count = proto.write_results_count;
  std::vector<MutationResult> results;
  results.reserve(count);

  nanopb::Reader reader;
  for (pb_size_t i = 0; i != count; ++i) {
    results.push_back(
        serializer_.DecodeMutationResult(&reader, writes[i], commit_version));
  };

  return results;
}

std::string WriteStreamSerializer::Describe(
    const Message<google_firestore_v1_WriteRequest>& request) {
  return DescribeMessage<GCFSWriteRequest>(request);
}

std::string WriteStreamSerializer::Describe(
    const Message<google_firestore_v1_WriteResponse>& response) {
  return DescribeMessage<GCFSWriteResponse>(response);
}

// DatastoreSerializer

DatastoreSerializer::DatastoreSerializer(const DatabaseInfo& database_info)
    : serializer_{database_info.database_id()} {
}

Message<google_firestore_v1_CommitRequest>
DatastoreSerializer::EncodeCommitRequest(
    const std::vector<Mutation>& mutations) const {
  Message<google_firestore_v1_CommitRequest> result{
      google_firestore_v1_CommitRequest_fields};
  auto& request = *result;

  request.database = serializer_.EncodeDatabaseName();

  if (!mutations.empty()) {
    request.writes_count = nanopb::CheckedSize(mutations.size());
    request.writes = MakeArray<google_firestore_v1_Write>(request.writes_count);
    pb_size_t i = 0;
    for (const Mutation& mutation : mutations) {
      request.writes[i] = serializer_.EncodeMutation(mutation);
      ++i;
    }
  }

  return result;
}

Message<google_firestore_v1_BatchGetDocumentsRequest>
DatastoreSerializer::EncodeLookupRequest(
    const std::vector<DocumentKey>& keys) const {
  Message<google_firestore_v1_BatchGetDocumentsRequest> result{
      google_firestore_v1_BatchGetDocumentsRequest_fields};
  auto& request = *result;

  request.database = serializer_.EncodeDatabaseName();
  if (!keys.empty()) {
    request.documents_count = nanopb::CheckedSize(keys.size());
    request.documents = MakeArray<pb_bytes_array_t*>(request.documents_count);
    pb_size_t i = 0;
    for (const DocumentKey& key : keys) {
      request.documents[i] = serializer_.EncodeKey(key);
      ++i;
    }
  }

  return result;
}

StatusOr<std::vector<model::MaybeDocument>>
DatastoreSerializer::MergeLookupResponses(
    const std::vector<grpc::ByteBuffer>& responses) const {
  // Sort by key.
  std::map<DocumentKey, MaybeDocument> results;

  for (const auto& response : responses) {
    auto maybe_proto =
        Message<google_firestore_v1_BatchGetDocumentsResponse>::TryDecode(
            response);
    if (!maybe_proto.ok()) {
      return maybe_proto.status();
    }

    const auto& proto = maybe_proto.ValueOrDie();
    nanopb::Reader reader;
    MaybeDocument doc = serializer_.DecodeMaybeDocument(&reader, *proto);
    results[doc.key()] = std::move(doc);
  }

  std::vector<MaybeDocument> docs;
  docs.reserve(results.size());
  for (const auto& kv : results) {
    docs.push_back(kv.second);
  }

  StatusOr<std::vector<model::MaybeDocument>> result{std::move(docs)};
  return result;
}

MaybeDocument DatastoreSerializer::ToMaybeDocument(
    const google_firestore_v1_BatchGetDocumentsResponse& response) const {
  nanopb::Reader reader;
  return serializer_.DecodeMaybeDocument(&reader, response);
}

}  // namespace remote
}  // namespace firestore
}  // namespace firebase
