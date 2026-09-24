// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'options.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$SshAuth {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is SshAuth);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'SshAuth()';
}


}

/// @nodoc
class $SshAuthCopyWith<$Res>  {
$SshAuthCopyWith(SshAuth _, $Res Function(SshAuth) __);
}


/// Adds pattern-matching-related methods to [SshAuth].
extension SshAuthPatterns on SshAuth {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( SshAuth_Password value)?  password,TResult Function( SshAuth_PrivateKey value)?  privateKey,TResult Function( SshAuth_Agent value)?  agent,required TResult orElse(),}){
final _that = this;
switch (_that) {
case SshAuth_Password() when password != null:
return password(_that);case SshAuth_PrivateKey() when privateKey != null:
return privateKey(_that);case SshAuth_Agent() when agent != null:
return agent(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( SshAuth_Password value)  password,required TResult Function( SshAuth_PrivateKey value)  privateKey,required TResult Function( SshAuth_Agent value)  agent,}){
final _that = this;
switch (_that) {
case SshAuth_Password():
return password(_that);case SshAuth_PrivateKey():
return privateKey(_that);case SshAuth_Agent():
return agent(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( SshAuth_Password value)?  password,TResult? Function( SshAuth_PrivateKey value)?  privateKey,TResult? Function( SshAuth_Agent value)?  agent,}){
final _that = this;
switch (_that) {
case SshAuth_Password() when password != null:
return password(_that);case SshAuth_PrivateKey() when privateKey != null:
return privateKey(_that);case SshAuth_Agent() when agent != null:
return agent(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  password,TResult Function( String path)?  privateKey,TResult Function()?  agent,required TResult orElse(),}) {final _that = this;
switch (_that) {
case SshAuth_Password() when password != null:
return password();case SshAuth_PrivateKey() when privateKey != null:
return privateKey(_that.path);case SshAuth_Agent() when agent != null:
return agent();case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  password,required TResult Function( String path)  privateKey,required TResult Function()  agent,}) {final _that = this;
switch (_that) {
case SshAuth_Password():
return password();case SshAuth_PrivateKey():
return privateKey(_that.path);case SshAuth_Agent():
return agent();}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  password,TResult? Function( String path)?  privateKey,TResult? Function()?  agent,}) {final _that = this;
switch (_that) {
case SshAuth_Password() when password != null:
return password();case SshAuth_PrivateKey() when privateKey != null:
return privateKey(_that.path);case SshAuth_Agent() when agent != null:
return agent();case _:
  return null;

}
}

}

/// @nodoc


class SshAuth_Password extends SshAuth {
  const SshAuth_Password(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is SshAuth_Password);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'SshAuth.password()';
}


}




/// @nodoc


class SshAuth_PrivateKey extends SshAuth {
  const SshAuth_PrivateKey({required this.path}): super._();
  

 final  String path;

/// Create a copy of SshAuth
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SshAuth_PrivateKeyCopyWith<SshAuth_PrivateKey> get copyWith => _$SshAuth_PrivateKeyCopyWithImpl<SshAuth_PrivateKey>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is SshAuth_PrivateKey&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode {
    return Object.hash(runtimeType,path);
}

@override
String toString() {
    return 'SshAuth.privateKey(path: $path)';
}


}

/// @nodoc
abstract mixin class $SshAuth_PrivateKeyCopyWith<$Res> implements $SshAuthCopyWith<$Res> {
  factory $SshAuth_PrivateKeyCopyWith(SshAuth_PrivateKey value, $Res Function(SshAuth_PrivateKey) _then) = _$SshAuth_PrivateKeyCopyWithImpl;
@useResult
$Res call({
 String path
});




}
/// @nodoc
class _$SshAuth_PrivateKeyCopyWithImpl<$Res>
    implements $SshAuth_PrivateKeyCopyWith<$Res> {
  _$SshAuth_PrivateKeyCopyWithImpl(this._self, this._then);

  final SshAuth_PrivateKey _self;
  final $Res Function(SshAuth_PrivateKey) _then;

/// Create a copy of SshAuth
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? path = null,}) {
  return _then(SshAuth_PrivateKey(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class SshAuth_Agent extends SshAuth {
  const SshAuth_Agent(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is SshAuth_Agent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'SshAuth.agent()';
}


}




// dart format on
