import { Type } from 'class-transformer';
import { IsBoolean, IsInt, IsOptional, IsString, IsUrl, Matches, Max, MaxLength, Min, MinLength } from 'class-validator';
import { KoreaderCreateRequestDto } from './koreader-requests.dto';

export class KoreaderHubPageDto {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(1000)
  page = 1;
}

export class KoreaderCollectionQueryDto extends KoreaderHubPageDto {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  bookId?: number;
}

export class KoreaderCollectionBookDto {
  @IsInt()
  @Min(1)
  bookId!: number;
}

export class KoreaderWishlistBookDto extends KoreaderCreateRequestDto {
  @IsOptional()
  @IsString()
  @MaxLength(2048)
  @IsUrl({ protocols: ['https'], require_protocol: true })
  coverUrl?: string;
}

export class KoreaderWishlistKeyDto {
  @IsString()
  @Matches(/^[a-f0-9]{32}$/)
  key!: string;
}

export class KoreaderCreateCollectionDto {
  @IsString()
  @MinLength(1)
  @MaxLength(255)
  name!: string;
}

export class KoreaderNextQueryDto {
  @Type(() => Number)
  @IsInt()
  @Min(1)
  bookId!: number;
}

export class KoreaderSocialSharingDto {
  @IsBoolean()
  share!: boolean;
}

export class KoreaderRecommendDto {
  @IsInt()
  @Min(1)
  bookId!: number;

  @IsOptional()
  @IsString()
  @MaxLength(280)
  note?: string;
}

export class KoreaderRecommendParamsDto {
  @Type(() => Number)
  @IsInt()
  @Min(1)
  bookId!: number;
}

export class KoreaderErrorReportDto {
  @IsString()
  @MaxLength(2000)
  message!: string;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  where?: string;

  @IsOptional()
  @IsString()
  @MaxLength(64)
  version?: string;

  @IsOptional()
  @IsString()
  @MaxLength(4000)
  trace?: string;
}
