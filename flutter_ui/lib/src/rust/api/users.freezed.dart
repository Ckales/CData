// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'users.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$GrantLevel {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is GrantLevel);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'GrantLevel()';
}


}

/// @nodoc
class $GrantLevelCopyWith<$Res>  {
$GrantLevelCopyWith(GrantLevel _, $Res Function(GrantLevel) __);
}


/// Adds pattern-matching-related methods to [GrantLevel].
extension GrantLevelPatterns on GrantLevel {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( GrantLevel_Global value)?  global,TResult Function( GrantLevel_Database value)?  database,TResult Function( GrantLevel_Table value)?  table,required TResult orElse(),}){
final _that = this;
switch (_that) {
case GrantLevel_Global() when global != null:
return global(_that);case GrantLevel_Database() when database != null:
return database(_that);case GrantLevel_Table() when table != null:
return table(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( GrantLevel_Global value)  global,required TResult Function( GrantLevel_Database value)  database,required TResult Function( GrantLevel_Table value)  table,}){
final _that = this;
switch (_that) {
case GrantLevel_Global():
return global(_that);case GrantLevel_Database():
return database(_that);case GrantLevel_Table():
return table(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( GrantLevel_Global value)?  global,TResult? Function( GrantLevel_Database value)?  database,TResult? Function( GrantLevel_Table value)?  table,}){
final _that = this;
switch (_that) {
case GrantLevel_Global() when global != null:
return global(_that);case GrantLevel_Database() when database != null:
return database(_that);case GrantLevel_Table() when table != null:
return table(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  global,TResult Function( String database)?  database,TResult Function( String database,  String table)?  table,required TResult orElse(),}) {final _that = this;
switch (_that) {
case GrantLevel_Global() when global != null:
return global();case GrantLevel_Database() when database != null:
return database(_that.database);case GrantLevel_Table() when table != null:
return table(_that.database,_that.table);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  global,required TResult Function( String database)  database,required TResult Function( String database,  String table)  table,}) {final _that = this;
switch (_that) {
case GrantLevel_Global():
return global();case GrantLevel_Database():
return database(_that.database);case GrantLevel_Table():
return table(_that.database,_that.table);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  global,TResult? Function( String database)?  database,TResult? Function( String database,  String table)?  table,}) {final _that = this;
switch (_that) {
case GrantLevel_Global() when global != null:
return global();case GrantLevel_Database() when database != null:
return database(_that.database);case GrantLevel_Table() when table != null:
return table(_that.database,_that.table);case _:
  return null;

}
}

}

/// @nodoc


class GrantLevel_Global extends GrantLevel {
  const GrantLevel_Global(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is GrantLevel_Global);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'GrantLevel.global()';
}


}




/// @nodoc


class GrantLevel_Database extends GrantLevel {
  const GrantLevel_Database({required this.database}): super._();
  

 final  String database;

/// Create a copy of GrantLevel
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$GrantLevel_DatabaseCopyWith<GrantLevel_Database> get copyWith => _$GrantLevel_DatabaseCopyWithImpl<GrantLevel_Database>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is GrantLevel_Database&&(identical(other.database, database) || other.database == database));
}


@override
int get hashCode {
    return Object.hash(runtimeType,database);
}

@override
String toString() {
    return 'GrantLevel.database(database: $database)';
}


}

/// @nodoc
abstract mixin class $GrantLevel_DatabaseCopyWith<$Res> implements $GrantLevelCopyWith<$Res> {
  factory $GrantLevel_DatabaseCopyWith(GrantLevel_Database value, $Res Function(GrantLevel_Database) _then) = _$GrantLevel_DatabaseCopyWithImpl;
@useResult
$Res call({
 String database
});




}
/// @nodoc
class _$GrantLevel_DatabaseCopyWithImpl<$Res>
    implements $GrantLevel_DatabaseCopyWith<$Res> {
  _$GrantLevel_DatabaseCopyWithImpl(this._self, this._then);

  final GrantLevel_Database _self;
  final $Res Function(GrantLevel_Database) _then;

/// Create a copy of GrantLevel
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? database = null,}) {
  return _then(GrantLevel_Database(
database: null == database ? _self.database : database // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class GrantLevel_Table extends GrantLevel {
  const GrantLevel_Table({required this.database, required this.table}): super._();
  

 final  String database;
 final  String table;

/// Create a copy of GrantLevel
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$GrantLevel_TableCopyWith<GrantLevel_Table> get copyWith => _$GrantLevel_TableCopyWithImpl<GrantLevel_Table>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is GrantLevel_Table&&(identical(other.database, database) || other.database == database)&&(identical(other.table, table) || other.table == table));
}


@override
int get hashCode {
    return Object.hash(runtimeType,database,table);
}

@override
String toString() {
    return 'GrantLevel.table(database: $database, table: $table)';
}


}

/// @nodoc
abstract mixin class $GrantLevel_TableCopyWith<$Res> implements $GrantLevelCopyWith<$Res> {
  factory $GrantLevel_TableCopyWith(GrantLevel_Table value, $Res Function(GrantLevel_Table) _then) = _$GrantLevel_TableCopyWithImpl;
@useResult
$Res call({
 String database, String table
});




}
/// @nodoc
class _$GrantLevel_TableCopyWithImpl<$Res>
    implements $GrantLevel_TableCopyWith<$Res> {
  _$GrantLevel_TableCopyWithImpl(this._self, this._then);

  final GrantLevel_Table _self;
  final $Res Function(GrantLevel_Table) _then;

/// Create a copy of GrantLevel
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? database = null,Object? table = null,}) {
  return _then(GrantLevel_Table(
database: null == database ? _self.database : database // ignore: cast_nullable_to_non_nullable
as String,table: null == table ? _self.table : table // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$UserChange {

 Account get account;
/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UserChangeCopyWith<UserChange> get copyWith => _$UserChangeCopyWithImpl<UserChange>(this as UserChange, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as UserChange;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UserChange&&(identical(other.account, _this.account) || other.account == _this.account));
}


@override
int get hashCode {
  final _this = this as UserChange;
  return Object.hash(runtimeType,_this.account);
}

@override
String toString() {
  final _this = this as UserChange;
  return 'UserChange(account: ${_this.account})';
}


}

/// @nodoc
abstract mixin class $UserChangeCopyWith<$Res>  {
  factory $UserChangeCopyWith(UserChange value, $Res Function(UserChange) _then) = _$UserChangeCopyWithImpl;
@useResult
$Res call({
 Account account
});




}
/// @nodoc
class _$UserChangeCopyWithImpl<$Res>
    implements $UserChangeCopyWith<$Res> {
  _$UserChangeCopyWithImpl(this._self, this._then);

  final UserChange _self;
  final $Res Function(UserChange) _then;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? account = null,}) {
  return _then(_self.copyWith(
account: null == account ? _self.account : account // ignore: cast_nullable_to_non_nullable
as Account,
  ));
}

}


/// Adds pattern-matching-related methods to [UserChange].
extension UserChangePatterns on UserChange {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( UserChange_Create value)?  create,TResult Function( UserChange_SetPassword value)?  setPassword,TResult Function( UserChange_SetLocked value)?  setLocked,TResult Function( UserChange_Drop value)?  drop,TResult Function( UserChange_Grant value)?  grant,TResult Function( UserChange_Revoke value)?  revoke,TResult Function( UserChange_GrantRole value)?  grantRole,TResult Function( UserChange_RevokeRole value)?  revokeRole,required TResult orElse(),}){
final _that = this;
switch (_that) {
case UserChange_Create() when create != null:
return create(_that);case UserChange_SetPassword() when setPassword != null:
return setPassword(_that);case UserChange_SetLocked() when setLocked != null:
return setLocked(_that);case UserChange_Drop() when drop != null:
return drop(_that);case UserChange_Grant() when grant != null:
return grant(_that);case UserChange_Revoke() when revoke != null:
return revoke(_that);case UserChange_GrantRole() when grantRole != null:
return grantRole(_that);case UserChange_RevokeRole() when revokeRole != null:
return revokeRole(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( UserChange_Create value)  create,required TResult Function( UserChange_SetPassword value)  setPassword,required TResult Function( UserChange_SetLocked value)  setLocked,required TResult Function( UserChange_Drop value)  drop,required TResult Function( UserChange_Grant value)  grant,required TResult Function( UserChange_Revoke value)  revoke,required TResult Function( UserChange_GrantRole value)  grantRole,required TResult Function( UserChange_RevokeRole value)  revokeRole,}){
final _that = this;
switch (_that) {
case UserChange_Create():
return create(_that);case UserChange_SetPassword():
return setPassword(_that);case UserChange_SetLocked():
return setLocked(_that);case UserChange_Drop():
return drop(_that);case UserChange_Grant():
return grant(_that);case UserChange_Revoke():
return revoke(_that);case UserChange_GrantRole():
return grantRole(_that);case UserChange_RevokeRole():
return revokeRole(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( UserChange_Create value)?  create,TResult? Function( UserChange_SetPassword value)?  setPassword,TResult? Function( UserChange_SetLocked value)?  setLocked,TResult? Function( UserChange_Drop value)?  drop,TResult? Function( UserChange_Grant value)?  grant,TResult? Function( UserChange_Revoke value)?  revoke,TResult? Function( UserChange_GrantRole value)?  grantRole,TResult? Function( UserChange_RevokeRole value)?  revokeRole,}){
final _that = this;
switch (_that) {
case UserChange_Create() when create != null:
return create(_that);case UserChange_SetPassword() when setPassword != null:
return setPassword(_that);case UserChange_SetLocked() when setLocked != null:
return setLocked(_that);case UserChange_Drop() when drop != null:
return drop(_that);case UserChange_Grant() when grant != null:
return grant(_that);case UserChange_Revoke() when revoke != null:
return revoke(_that);case UserChange_GrantRole() when grantRole != null:
return grantRole(_that);case UserChange_RevokeRole() when revokeRole != null:
return revokeRole(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( Account account,  String? plugin)?  create,TResult Function( Account account)?  setPassword,TResult Function( Account account,  bool locked)?  setLocked,TResult Function( Account account)?  drop,TResult Function( Account account,  GrantLevel level,  List<String> privileges,  bool withGrantOption)?  grant,TResult Function( Account account,  GrantLevel level,  List<String> privileges)?  revoke,TResult Function( Account account,  Account role)?  grantRole,TResult Function( Account account,  Account role)?  revokeRole,required TResult orElse(),}) {final _that = this;
switch (_that) {
case UserChange_Create() when create != null:
return create(_that.account,_that.plugin);case UserChange_SetPassword() when setPassword != null:
return setPassword(_that.account);case UserChange_SetLocked() when setLocked != null:
return setLocked(_that.account,_that.locked);case UserChange_Drop() when drop != null:
return drop(_that.account);case UserChange_Grant() when grant != null:
return grant(_that.account,_that.level,_that.privileges,_that.withGrantOption);case UserChange_Revoke() when revoke != null:
return revoke(_that.account,_that.level,_that.privileges);case UserChange_GrantRole() when grantRole != null:
return grantRole(_that.account,_that.role);case UserChange_RevokeRole() when revokeRole != null:
return revokeRole(_that.account,_that.role);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( Account account,  String? plugin)  create,required TResult Function( Account account)  setPassword,required TResult Function( Account account,  bool locked)  setLocked,required TResult Function( Account account)  drop,required TResult Function( Account account,  GrantLevel level,  List<String> privileges,  bool withGrantOption)  grant,required TResult Function( Account account,  GrantLevel level,  List<String> privileges)  revoke,required TResult Function( Account account,  Account role)  grantRole,required TResult Function( Account account,  Account role)  revokeRole,}) {final _that = this;
switch (_that) {
case UserChange_Create():
return create(_that.account,_that.plugin);case UserChange_SetPassword():
return setPassword(_that.account);case UserChange_SetLocked():
return setLocked(_that.account,_that.locked);case UserChange_Drop():
return drop(_that.account);case UserChange_Grant():
return grant(_that.account,_that.level,_that.privileges,_that.withGrantOption);case UserChange_Revoke():
return revoke(_that.account,_that.level,_that.privileges);case UserChange_GrantRole():
return grantRole(_that.account,_that.role);case UserChange_RevokeRole():
return revokeRole(_that.account,_that.role);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( Account account,  String? plugin)?  create,TResult? Function( Account account)?  setPassword,TResult? Function( Account account,  bool locked)?  setLocked,TResult? Function( Account account)?  drop,TResult? Function( Account account,  GrantLevel level,  List<String> privileges,  bool withGrantOption)?  grant,TResult? Function( Account account,  GrantLevel level,  List<String> privileges)?  revoke,TResult? Function( Account account,  Account role)?  grantRole,TResult? Function( Account account,  Account role)?  revokeRole,}) {final _that = this;
switch (_that) {
case UserChange_Create() when create != null:
return create(_that.account,_that.plugin);case UserChange_SetPassword() when setPassword != null:
return setPassword(_that.account);case UserChange_SetLocked() when setLocked != null:
return setLocked(_that.account,_that.locked);case UserChange_Drop() when drop != null:
return drop(_that.account);case UserChange_Grant() when grant != null:
return grant(_that.account,_that.level,_that.privileges,_that.withGrantOption);case UserChange_Revoke() when revoke != null:
return revoke(_that.account,_that.level,_that.privileges);case UserChange_GrantRole() when grantRole != null:
return grantRole(_that.account,_that.role);case UserChange_RevokeRole() when revokeRole != null:
return revokeRole(_that.account,_that.role);case _:
  return null;

}
}

}

/// @nodoc


class UserChange_Create extends UserChange {
  const UserChange_Create({required this.account, this.plugin}): super._();
  

@override final  Account account;
 final  String? plugin;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UserChange_CreateCopyWith<UserChange_Create> get copyWith => _$UserChange_CreateCopyWithImpl<UserChange_Create>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UserChange_Create&&(identical(other.account, account) || other.account == account)&&(identical(other.plugin, plugin) || other.plugin == plugin));
}


@override
int get hashCode {
    return Object.hash(runtimeType,account,plugin);
}

@override
String toString() {
    return 'UserChange.create(account: $account, plugin: $plugin)';
}


}

/// @nodoc
abstract mixin class $UserChange_CreateCopyWith<$Res> implements $UserChangeCopyWith<$Res> {
  factory $UserChange_CreateCopyWith(UserChange_Create value, $Res Function(UserChange_Create) _then) = _$UserChange_CreateCopyWithImpl;
@override @useResult
$Res call({
 Account account, String? plugin
});




}
/// @nodoc
class _$UserChange_CreateCopyWithImpl<$Res>
    implements $UserChange_CreateCopyWith<$Res> {
  _$UserChange_CreateCopyWithImpl(this._self, this._then);

  final UserChange_Create _self;
  final $Res Function(UserChange_Create) _then;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? account = null,Object? plugin = freezed,}) {
  return _then(UserChange_Create(
account: null == account ? _self.account : account // ignore: cast_nullable_to_non_nullable
as Account,plugin: freezed == plugin ? _self.plugin : plugin // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class UserChange_SetPassword extends UserChange {
  const UserChange_SetPassword({required this.account}): super._();
  

@override final  Account account;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UserChange_SetPasswordCopyWith<UserChange_SetPassword> get copyWith => _$UserChange_SetPasswordCopyWithImpl<UserChange_SetPassword>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UserChange_SetPassword&&(identical(other.account, account) || other.account == account));
}


@override
int get hashCode {
    return Object.hash(runtimeType,account);
}

@override
String toString() {
    return 'UserChange.setPassword(account: $account)';
}


}

/// @nodoc
abstract mixin class $UserChange_SetPasswordCopyWith<$Res> implements $UserChangeCopyWith<$Res> {
  factory $UserChange_SetPasswordCopyWith(UserChange_SetPassword value, $Res Function(UserChange_SetPassword) _then) = _$UserChange_SetPasswordCopyWithImpl;
@override @useResult
$Res call({
 Account account
});




}
/// @nodoc
class _$UserChange_SetPasswordCopyWithImpl<$Res>
    implements $UserChange_SetPasswordCopyWith<$Res> {
  _$UserChange_SetPasswordCopyWithImpl(this._self, this._then);

  final UserChange_SetPassword _self;
  final $Res Function(UserChange_SetPassword) _then;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? account = null,}) {
  return _then(UserChange_SetPassword(
account: null == account ? _self.account : account // ignore: cast_nullable_to_non_nullable
as Account,
  ));
}


}

/// @nodoc


class UserChange_SetLocked extends UserChange {
  const UserChange_SetLocked({required this.account, required this.locked}): super._();
  

@override final  Account account;
 final  bool locked;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UserChange_SetLockedCopyWith<UserChange_SetLocked> get copyWith => _$UserChange_SetLockedCopyWithImpl<UserChange_SetLocked>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UserChange_SetLocked&&(identical(other.account, account) || other.account == account)&&(identical(other.locked, locked) || other.locked == locked));
}


@override
int get hashCode {
    return Object.hash(runtimeType,account,locked);
}

@override
String toString() {
    return 'UserChange.setLocked(account: $account, locked: $locked)';
}


}

/// @nodoc
abstract mixin class $UserChange_SetLockedCopyWith<$Res> implements $UserChangeCopyWith<$Res> {
  factory $UserChange_SetLockedCopyWith(UserChange_SetLocked value, $Res Function(UserChange_SetLocked) _then) = _$UserChange_SetLockedCopyWithImpl;
@override @useResult
$Res call({
 Account account, bool locked
});




}
/// @nodoc
class _$UserChange_SetLockedCopyWithImpl<$Res>
    implements $UserChange_SetLockedCopyWith<$Res> {
  _$UserChange_SetLockedCopyWithImpl(this._self, this._then);

  final UserChange_SetLocked _self;
  final $Res Function(UserChange_SetLocked) _then;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? account = null,Object? locked = null,}) {
  return _then(UserChange_SetLocked(
account: null == account ? _self.account : account // ignore: cast_nullable_to_non_nullable
as Account,locked: null == locked ? _self.locked : locked // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class UserChange_Drop extends UserChange {
  const UserChange_Drop({required this.account}): super._();
  

@override final  Account account;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UserChange_DropCopyWith<UserChange_Drop> get copyWith => _$UserChange_DropCopyWithImpl<UserChange_Drop>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UserChange_Drop&&(identical(other.account, account) || other.account == account));
}


@override
int get hashCode {
    return Object.hash(runtimeType,account);
}

@override
String toString() {
    return 'UserChange.drop(account: $account)';
}


}

/// @nodoc
abstract mixin class $UserChange_DropCopyWith<$Res> implements $UserChangeCopyWith<$Res> {
  factory $UserChange_DropCopyWith(UserChange_Drop value, $Res Function(UserChange_Drop) _then) = _$UserChange_DropCopyWithImpl;
@override @useResult
$Res call({
 Account account
});




}
/// @nodoc
class _$UserChange_DropCopyWithImpl<$Res>
    implements $UserChange_DropCopyWith<$Res> {
  _$UserChange_DropCopyWithImpl(this._self, this._then);

  final UserChange_Drop _self;
  final $Res Function(UserChange_Drop) _then;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? account = null,}) {
  return _then(UserChange_Drop(
account: null == account ? _self.account : account // ignore: cast_nullable_to_non_nullable
as Account,
  ));
}


}

/// @nodoc


class UserChange_Grant extends UserChange {
  const UserChange_Grant({required this.account, required this.level, required  List<String> privileges, required this.withGrantOption}): _privileges = privileges,super._();
  

@override final  Account account;
 final  GrantLevel level;
 final  List<String> _privileges;
 List<String> get privileges {
  if (_privileges is EqualUnmodifiableListView) return _privileges;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_privileges);
}

 final  bool withGrantOption;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UserChange_GrantCopyWith<UserChange_Grant> get copyWith => _$UserChange_GrantCopyWithImpl<UserChange_Grant>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UserChange_Grant&&(identical(other.account, account) || other.account == account)&&(identical(other.level, level) || other.level == level)&&const DeepCollectionEquality().equals(other.privileges, _privileges)&&(identical(other.withGrantOption, withGrantOption) || other.withGrantOption == withGrantOption));
}


@override
int get hashCode {
    return Object.hash(runtimeType,account,level,const DeepCollectionEquality().hash(_privileges),withGrantOption);
}

@override
String toString() {
    return 'UserChange.grant(account: $account, level: $level, privileges: $privileges, withGrantOption: $withGrantOption)';
}


}

/// @nodoc
abstract mixin class $UserChange_GrantCopyWith<$Res> implements $UserChangeCopyWith<$Res> {
  factory $UserChange_GrantCopyWith(UserChange_Grant value, $Res Function(UserChange_Grant) _then) = _$UserChange_GrantCopyWithImpl;
@override @useResult
$Res call({
 Account account, GrantLevel level, List<String> privileges, bool withGrantOption
});


$GrantLevelCopyWith<$Res> get level;

}
/// @nodoc
class _$UserChange_GrantCopyWithImpl<$Res>
    implements $UserChange_GrantCopyWith<$Res> {
  _$UserChange_GrantCopyWithImpl(this._self, this._then);

  final UserChange_Grant _self;
  final $Res Function(UserChange_Grant) _then;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? account = null,Object? level = null,Object? privileges = null,Object? withGrantOption = null,}) {
  return _then(UserChange_Grant(
account: null == account ? _self.account : account // ignore: cast_nullable_to_non_nullable
as Account,level: null == level ? _self.level : level // ignore: cast_nullable_to_non_nullable
as GrantLevel,privileges: null == privileges ? _self._privileges : privileges // ignore: cast_nullable_to_non_nullable
as List<String>,withGrantOption: null == withGrantOption ? _self.withGrantOption : withGrantOption // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$GrantLevelCopyWith<$Res> get level {
  
  return $GrantLevelCopyWith<$Res>(_self.level, (value) {
    return _then(_self.copyWith(level: value));
  });
}
}

/// @nodoc


class UserChange_Revoke extends UserChange {
  const UserChange_Revoke({required this.account, required this.level, required  List<String> privileges}): _privileges = privileges,super._();
  

@override final  Account account;
 final  GrantLevel level;
 final  List<String> _privileges;
 List<String> get privileges {
  if (_privileges is EqualUnmodifiableListView) return _privileges;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_privileges);
}


/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UserChange_RevokeCopyWith<UserChange_Revoke> get copyWith => _$UserChange_RevokeCopyWithImpl<UserChange_Revoke>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UserChange_Revoke&&(identical(other.account, account) || other.account == account)&&(identical(other.level, level) || other.level == level)&&const DeepCollectionEquality().equals(other.privileges, _privileges));
}


@override
int get hashCode {
    return Object.hash(runtimeType,account,level,const DeepCollectionEquality().hash(_privileges));
}

@override
String toString() {
    return 'UserChange.revoke(account: $account, level: $level, privileges: $privileges)';
}


}

/// @nodoc
abstract mixin class $UserChange_RevokeCopyWith<$Res> implements $UserChangeCopyWith<$Res> {
  factory $UserChange_RevokeCopyWith(UserChange_Revoke value, $Res Function(UserChange_Revoke) _then) = _$UserChange_RevokeCopyWithImpl;
@override @useResult
$Res call({
 Account account, GrantLevel level, List<String> privileges
});


$GrantLevelCopyWith<$Res> get level;

}
/// @nodoc
class _$UserChange_RevokeCopyWithImpl<$Res>
    implements $UserChange_RevokeCopyWith<$Res> {
  _$UserChange_RevokeCopyWithImpl(this._self, this._then);

  final UserChange_Revoke _self;
  final $Res Function(UserChange_Revoke) _then;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? account = null,Object? level = null,Object? privileges = null,}) {
  return _then(UserChange_Revoke(
account: null == account ? _self.account : account // ignore: cast_nullable_to_non_nullable
as Account,level: null == level ? _self.level : level // ignore: cast_nullable_to_non_nullable
as GrantLevel,privileges: null == privileges ? _self._privileges : privileges // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$GrantLevelCopyWith<$Res> get level {
  
  return $GrantLevelCopyWith<$Res>(_self.level, (value) {
    return _then(_self.copyWith(level: value));
  });
}
}

/// @nodoc


class UserChange_GrantRole extends UserChange {
  const UserChange_GrantRole({required this.account, required this.role}): super._();
  

@override final  Account account;
 final  Account role;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UserChange_GrantRoleCopyWith<UserChange_GrantRole> get copyWith => _$UserChange_GrantRoleCopyWithImpl<UserChange_GrantRole>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UserChange_GrantRole&&(identical(other.account, account) || other.account == account)&&(identical(other.role, role) || other.role == role));
}


@override
int get hashCode {
    return Object.hash(runtimeType,account,role);
}

@override
String toString() {
    return 'UserChange.grantRole(account: $account, role: $role)';
}


}

/// @nodoc
abstract mixin class $UserChange_GrantRoleCopyWith<$Res> implements $UserChangeCopyWith<$Res> {
  factory $UserChange_GrantRoleCopyWith(UserChange_GrantRole value, $Res Function(UserChange_GrantRole) _then) = _$UserChange_GrantRoleCopyWithImpl;
@override @useResult
$Res call({
 Account account, Account role
});




}
/// @nodoc
class _$UserChange_GrantRoleCopyWithImpl<$Res>
    implements $UserChange_GrantRoleCopyWith<$Res> {
  _$UserChange_GrantRoleCopyWithImpl(this._self, this._then);

  final UserChange_GrantRole _self;
  final $Res Function(UserChange_GrantRole) _then;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? account = null,Object? role = null,}) {
  return _then(UserChange_GrantRole(
account: null == account ? _self.account : account // ignore: cast_nullable_to_non_nullable
as Account,role: null == role ? _self.role : role // ignore: cast_nullable_to_non_nullable
as Account,
  ));
}


}

/// @nodoc


class UserChange_RevokeRole extends UserChange {
  const UserChange_RevokeRole({required this.account, required this.role}): super._();
  

@override final  Account account;
 final  Account role;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UserChange_RevokeRoleCopyWith<UserChange_RevokeRole> get copyWith => _$UserChange_RevokeRoleCopyWithImpl<UserChange_RevokeRole>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UserChange_RevokeRole&&(identical(other.account, account) || other.account == account)&&(identical(other.role, role) || other.role == role));
}


@override
int get hashCode {
    return Object.hash(runtimeType,account,role);
}

@override
String toString() {
    return 'UserChange.revokeRole(account: $account, role: $role)';
}


}

/// @nodoc
abstract mixin class $UserChange_RevokeRoleCopyWith<$Res> implements $UserChangeCopyWith<$Res> {
  factory $UserChange_RevokeRoleCopyWith(UserChange_RevokeRole value, $Res Function(UserChange_RevokeRole) _then) = _$UserChange_RevokeRoleCopyWithImpl;
@override @useResult
$Res call({
 Account account, Account role
});




}
/// @nodoc
class _$UserChange_RevokeRoleCopyWithImpl<$Res>
    implements $UserChange_RevokeRoleCopyWith<$Res> {
  _$UserChange_RevokeRoleCopyWithImpl(this._self, this._then);

  final UserChange_RevokeRole _self;
  final $Res Function(UserChange_RevokeRole) _then;

/// Create a copy of UserChange
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? account = null,Object? role = null,}) {
  return _then(UserChange_RevokeRole(
account: null == account ? _self.account : account // ignore: cast_nullable_to_non_nullable
as Account,role: null == role ? _self.role : role // ignore: cast_nullable_to_non_nullable
as Account,
  ));
}


}

// dart format on
