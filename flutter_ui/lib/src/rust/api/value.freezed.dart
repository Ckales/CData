// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'value.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$CellValue {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CellValue);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'CellValue()';
}


}

/// @nodoc
class $CellValueCopyWith<$Res>  {
$CellValueCopyWith(CellValue _, $Res Function(CellValue) __);
}


/// Adds pattern-matching-related methods to [CellValue].
extension CellValuePatterns on CellValue {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( CellValue_Null value)?  null_,TResult Function( CellValue_Int value)?  int,TResult Function( CellValue_UInt value)?  uInt,TResult Function( CellValue_Double value)?  double,TResult Function( CellValue_Text value)?  text,TResult Function( CellValue_Bytes value)?  bytes,TResult Function( CellValue_InvalidText value)?  invalidText,required TResult orElse(),}){
final _that = this;
switch (_that) {
case CellValue_Null() when null_ != null:
return null_(_that);case CellValue_Int() when int != null:
return int(_that);case CellValue_UInt() when uInt != null:
return uInt(_that);case CellValue_Double() when double != null:
return double(_that);case CellValue_Text() when text != null:
return text(_that);case CellValue_Bytes() when bytes != null:
return bytes(_that);case CellValue_InvalidText() when invalidText != null:
return invalidText(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( CellValue_Null value)  null_,required TResult Function( CellValue_Int value)  int,required TResult Function( CellValue_UInt value)  uInt,required TResult Function( CellValue_Double value)  double,required TResult Function( CellValue_Text value)  text,required TResult Function( CellValue_Bytes value)  bytes,required TResult Function( CellValue_InvalidText value)  invalidText,}){
final _that = this;
switch (_that) {
case CellValue_Null():
return null_(_that);case CellValue_Int():
return int(_that);case CellValue_UInt():
return uInt(_that);case CellValue_Double():
return double(_that);case CellValue_Text():
return text(_that);case CellValue_Bytes():
return bytes(_that);case CellValue_InvalidText():
return invalidText(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( CellValue_Null value)?  null_,TResult? Function( CellValue_Int value)?  int,TResult? Function( CellValue_UInt value)?  uInt,TResult? Function( CellValue_Double value)?  double,TResult? Function( CellValue_Text value)?  text,TResult? Function( CellValue_Bytes value)?  bytes,TResult? Function( CellValue_InvalidText value)?  invalidText,}){
final _that = this;
switch (_that) {
case CellValue_Null() when null_ != null:
return null_(_that);case CellValue_Int() when int != null:
return int(_that);case CellValue_UInt() when uInt != null:
return uInt(_that);case CellValue_Double() when double != null:
return double(_that);case CellValue_Text() when text != null:
return text(_that);case CellValue_Bytes() when bytes != null:
return bytes(_that);case CellValue_InvalidText() when invalidText != null:
return invalidText(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  null_,TResult Function( PlatformInt64 field0)?  int,TResult Function( BigInt field0)?  uInt,TResult Function( double field0)?  double,TResult Function( String field0)?  text,TResult Function( Uint8List field0)?  bytes,TResult Function( Uint8List field0)?  invalidText,required TResult orElse(),}) {final _that = this;
switch (_that) {
case CellValue_Null() when null_ != null:
return null_();case CellValue_Int() when int != null:
return int(_that.field0);case CellValue_UInt() when uInt != null:
return uInt(_that.field0);case CellValue_Double() when double != null:
return double(_that.field0);case CellValue_Text() when text != null:
return text(_that.field0);case CellValue_Bytes() when bytes != null:
return bytes(_that.field0);case CellValue_InvalidText() when invalidText != null:
return invalidText(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  null_,required TResult Function( PlatformInt64 field0)  int,required TResult Function( BigInt field0)  uInt,required TResult Function( double field0)  double,required TResult Function( String field0)  text,required TResult Function( Uint8List field0)  bytes,required TResult Function( Uint8List field0)  invalidText,}) {final _that = this;
switch (_that) {
case CellValue_Null():
return null_();case CellValue_Int():
return int(_that.field0);case CellValue_UInt():
return uInt(_that.field0);case CellValue_Double():
return double(_that.field0);case CellValue_Text():
return text(_that.field0);case CellValue_Bytes():
return bytes(_that.field0);case CellValue_InvalidText():
return invalidText(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  null_,TResult? Function( PlatformInt64 field0)?  int,TResult? Function( BigInt field0)?  uInt,TResult? Function( double field0)?  double,TResult? Function( String field0)?  text,TResult? Function( Uint8List field0)?  bytes,TResult? Function( Uint8List field0)?  invalidText,}) {final _that = this;
switch (_that) {
case CellValue_Null() when null_ != null:
return null_();case CellValue_Int() when int != null:
return int(_that.field0);case CellValue_UInt() when uInt != null:
return uInt(_that.field0);case CellValue_Double() when double != null:
return double(_that.field0);case CellValue_Text() when text != null:
return text(_that.field0);case CellValue_Bytes() when bytes != null:
return bytes(_that.field0);case CellValue_InvalidText() when invalidText != null:
return invalidText(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class CellValue_Null extends CellValue {
  const CellValue_Null(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CellValue_Null);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'CellValue.null_()';
}


}




/// @nodoc


class CellValue_Int extends CellValue {
  const CellValue_Int(this.field0): super._();
  

 final  PlatformInt64 field0;

/// Create a copy of CellValue
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CellValue_IntCopyWith<CellValue_Int> get copyWith => _$CellValue_IntCopyWithImpl<CellValue_Int>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CellValue_Int&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'CellValue.int(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $CellValue_IntCopyWith<$Res> implements $CellValueCopyWith<$Res> {
  factory $CellValue_IntCopyWith(CellValue_Int value, $Res Function(CellValue_Int) _then) = _$CellValue_IntCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 field0
});




}
/// @nodoc
class _$CellValue_IntCopyWithImpl<$Res>
    implements $CellValue_IntCopyWith<$Res> {
  _$CellValue_IntCopyWithImpl(this._self, this._then);

  final CellValue_Int _self;
  final $Res Function(CellValue_Int) _then;

/// Create a copy of CellValue
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(CellValue_Int(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class CellValue_UInt extends CellValue {
  const CellValue_UInt(this.field0): super._();
  

 final  BigInt field0;

/// Create a copy of CellValue
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CellValue_UIntCopyWith<CellValue_UInt> get copyWith => _$CellValue_UIntCopyWithImpl<CellValue_UInt>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CellValue_UInt&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'CellValue.uInt(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $CellValue_UIntCopyWith<$Res> implements $CellValueCopyWith<$Res> {
  factory $CellValue_UIntCopyWith(CellValue_UInt value, $Res Function(CellValue_UInt) _then) = _$CellValue_UIntCopyWithImpl;
@useResult
$Res call({
 BigInt field0
});




}
/// @nodoc
class _$CellValue_UIntCopyWithImpl<$Res>
    implements $CellValue_UIntCopyWith<$Res> {
  _$CellValue_UIntCopyWithImpl(this._self, this._then);

  final CellValue_UInt _self;
  final $Res Function(CellValue_UInt) _then;

/// Create a copy of CellValue
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(CellValue_UInt(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class CellValue_Double extends CellValue {
  const CellValue_Double(this.field0): super._();
  

 final  double field0;

/// Create a copy of CellValue
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CellValue_DoubleCopyWith<CellValue_Double> get copyWith => _$CellValue_DoubleCopyWithImpl<CellValue_Double>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CellValue_Double&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'CellValue.double(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $CellValue_DoubleCopyWith<$Res> implements $CellValueCopyWith<$Res> {
  factory $CellValue_DoubleCopyWith(CellValue_Double value, $Res Function(CellValue_Double) _then) = _$CellValue_DoubleCopyWithImpl;
@useResult
$Res call({
 double field0
});




}
/// @nodoc
class _$CellValue_DoubleCopyWithImpl<$Res>
    implements $CellValue_DoubleCopyWith<$Res> {
  _$CellValue_DoubleCopyWithImpl(this._self, this._then);

  final CellValue_Double _self;
  final $Res Function(CellValue_Double) _then;

/// Create a copy of CellValue
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(CellValue_Double(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class CellValue_Text extends CellValue {
  const CellValue_Text(this.field0): super._();
  

 final  String field0;

/// Create a copy of CellValue
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CellValue_TextCopyWith<CellValue_Text> get copyWith => _$CellValue_TextCopyWithImpl<CellValue_Text>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CellValue_Text&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'CellValue.text(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $CellValue_TextCopyWith<$Res> implements $CellValueCopyWith<$Res> {
  factory $CellValue_TextCopyWith(CellValue_Text value, $Res Function(CellValue_Text) _then) = _$CellValue_TextCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$CellValue_TextCopyWithImpl<$Res>
    implements $CellValue_TextCopyWith<$Res> {
  _$CellValue_TextCopyWithImpl(this._self, this._then);

  final CellValue_Text _self;
  final $Res Function(CellValue_Text) _then;

/// Create a copy of CellValue
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(CellValue_Text(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class CellValue_Bytes extends CellValue {
  const CellValue_Bytes(this.field0): super._();
  

 final  Uint8List field0;

/// Create a copy of CellValue
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CellValue_BytesCopyWith<CellValue_Bytes> get copyWith => _$CellValue_BytesCopyWithImpl<CellValue_Bytes>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CellValue_Bytes&&const DeepCollectionEquality().equals(other.field0, field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,const DeepCollectionEquality().hash(field0));
}

@override
String toString() {
    return 'CellValue.bytes(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $CellValue_BytesCopyWith<$Res> implements $CellValueCopyWith<$Res> {
  factory $CellValue_BytesCopyWith(CellValue_Bytes value, $Res Function(CellValue_Bytes) _then) = _$CellValue_BytesCopyWithImpl;
@useResult
$Res call({
 Uint8List field0
});




}
/// @nodoc
class _$CellValue_BytesCopyWithImpl<$Res>
    implements $CellValue_BytesCopyWith<$Res> {
  _$CellValue_BytesCopyWithImpl(this._self, this._then);

  final CellValue_Bytes _self;
  final $Res Function(CellValue_Bytes) _then;

/// Create a copy of CellValue
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(CellValue_Bytes(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as Uint8List,
  ));
}


}

/// @nodoc


class CellValue_InvalidText extends CellValue {
  const CellValue_InvalidText(this.field0): super._();
  

 final  Uint8List field0;

/// Create a copy of CellValue
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CellValue_InvalidTextCopyWith<CellValue_InvalidText> get copyWith => _$CellValue_InvalidTextCopyWithImpl<CellValue_InvalidText>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is CellValue_InvalidText&&const DeepCollectionEquality().equals(other.field0, field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,const DeepCollectionEquality().hash(field0));
}

@override
String toString() {
    return 'CellValue.invalidText(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $CellValue_InvalidTextCopyWith<$Res> implements $CellValueCopyWith<$Res> {
  factory $CellValue_InvalidTextCopyWith(CellValue_InvalidText value, $Res Function(CellValue_InvalidText) _then) = _$CellValue_InvalidTextCopyWithImpl;
@useResult
$Res call({
 Uint8List field0
});




}
/// @nodoc
class _$CellValue_InvalidTextCopyWithImpl<$Res>
    implements $CellValue_InvalidTextCopyWith<$Res> {
  _$CellValue_InvalidTextCopyWithImpl(this._self, this._then);

  final CellValue_InvalidText _self;
  final $Res Function(CellValue_InvalidText) _then;

/// Create a copy of CellValue
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(CellValue_InvalidText(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as Uint8List,
  ));
}


}

// dart format on
